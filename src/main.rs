mod player;
mod skin;
mod ui;

use anyhow::Result;
use eframe::egui;
use player::{Album, Artist, AudioPlayer, SubsonicClient, SubsonicConfig, Track};
use skin::SkinTextures;
use std::sync::{Arc, Mutex};
use ui::library::LibView;

// Winamp window sizes
const PLAYER_SIZE:   [f32; 2] = [275.0, 116.0];
const PLAYLIST_SIZE: [f32; 2] = [275.0, 232.0];
const LIBRARY_SIZE:  [f32; 2] = [400.0, 500.0];

const SNAP_DIST: f32 = 10.0;

const DEFAULT_SKIN: &str = "skins/winamp.wsz";

fn main() -> Result<(), eframe::Error> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("hagtamp")
            .with_inner_size(PLAYER_SIZE)
            .with_resizable(false)
            .with_decorations(false),
        ..Default::default()
    };

    eframe::run_native(
        "hagtamp",
        options,
        Box::new(|_cc| Ok(Box::new(App::default()))),
    )
}

struct App {
    state: AppState,
    skin: Option<SkinTextures>,
    skin_loaded: bool,
    // Window positions
    player_pos:   Option<egui::Pos2>,
    playlist_pos: egui::Pos2,
    library_pos:  egui::Pos2,
    // Snapping: last known player position to detect moves
    last_player_pos: Option<egui::Pos2>,
}

impl Default for App {
    fn default() -> Self {
        Self {
            state: AppState::new(AudioPlayer::new().ok()),
            skin: None,
            skin_loaded: false,
            player_pos: None,
            playlist_pos: egui::pos2(20.0, 140.0),
            library_pos:  egui::pos2(305.0, 20.0),
            last_player_pos: None,
        }
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        ctx.set_visuals(egui::Visuals::dark());

        // Load skin on first frame (needs ctx)
        if !self.skin_loaded {
            self.skin_loaded = true;
            let path = std::path::Path::new(DEFAULT_SKIN);
            match SkinTextures::load(ctx, path) {
                Ok(s) => self.skin = Some(s),
                Err(e) => eprintln!("Failed to load skin: {e}"),
            }
        }

        self.state.poll(ctx);

        // ── Player window (main viewport) ────────────────────────────────────
        // Track player position for snapping
        let outer = ctx.input(|i| i.viewport().outer_rect);
        if let Some(rect) = outer {
            let pos = rect.min;
            if self.player_pos.is_none() {
                self.player_pos = Some(pos);
                self.last_player_pos = Some(pos);
                // Set initial positions for child windows
                self.playlist_pos = egui::pos2(pos.x, pos.y + PLAYER_SIZE[1]);
                self.library_pos  = egui::pos2(pos.x + PLAYER_SIZE[0] + 5.0, pos.y);
            } else if self.last_player_pos != Some(pos) {
                // Player was moved — move snapped windows with it
                if let (Some(last), Some(prev)) = (self.player_pos, self.last_player_pos) {
                    let delta = pos - prev;
                    // Move playlist if it was snapped below player
                    if is_snapped(self.playlist_pos, last, PLAYER_SIZE) {
                        self.playlist_pos += delta;
                    }
                }
                self.player_pos = Some(pos);
                self.last_player_pos = Some(pos);
            }
        }

        // Render player
        egui::CentralPanel::default()
            .frame(egui::Frame::none())
            .show(ctx, |ui| {
                if let Some(skin) = &self.skin {
                    ui::player_window::render(ui, skin, &mut self.state);
                } else {
                    ui.label("Loading skin…");
                }
            });

        // Settings overlay
        if self.state.show_settings || self.state.client.is_none() {
            ui::settings::show(ctx, &mut self.state);
        }

        // ── Playlist viewport ────────────────────────────────────────────────
        let playlist_pos = self.playlist_pos;
        let player_pos   = self.player_pos.unwrap_or(egui::pos2(20.0, 20.0));
        let has_skin     = self.skin.is_some();

        // We need to split borrows: pass skin and state separately into the closure.
        // Use a raw pointer trick to satisfy the borrow checker for the closure.
        let skin_ptr  = &self.skin    as *const Option<SkinTextures>;
        let state_ptr = &mut self.state as *mut AppState;

        ctx.show_viewport_immediate(
            egui::ViewportId::from_hash_of("playlist"),
            egui::ViewportBuilder::default()
                .with_title("WINAMP PLAYLIST")
                .with_inner_size(PLAYLIST_SIZE)
                .with_resizable(true)
                .with_decorations(false)
                .with_position(playlist_pos),
            move |ctx, _class| {
                egui::CentralPanel::default()
                    .frame(egui::Frame::none())
                    .show(ctx, |ui| {
                        // SAFETY: skin and state live for the full duration of App::update
                        let skin_ref  = unsafe { &*skin_ptr };
                        let state_ref = unsafe { &mut *state_ptr };
                        if let Some(skin) = skin_ref {
                            ui::playlist::render(ui, skin, state_ref);
                        } else {
                            ui::playlist::render_plain(ui, state_ref);
                        }
                    });
            },
        );

        // Snap playlist to player bottom
        self.try_snap_playlist(player_pos);

        // ── Library viewport ─────────────────────────────────────────────────
        if self.state.client.is_some() {
            let lib_pos   = self.library_pos;
            let state_ptr = &mut self.state as *mut AppState;
            ctx.show_viewport_immediate(
                egui::ViewportId::from_hash_of("library"),
                egui::ViewportBuilder::default()
                    .with_title("MEDIA LIBRARY")
                    .with_inner_size(LIBRARY_SIZE)
                    .with_resizable(true)
                    .with_decorations(true)
                    .with_position(lib_pos),
                move |ctx, _class| {
                    let state_ref = unsafe { &mut *state_ptr };
                    egui::CentralPanel::default().show(ctx, |ui| {
                        ui::library::show(ctx, ui, state_ref);
                    });
                },
            );
        }
    }
}

impl App {
    fn try_snap_playlist(&mut self, player_pos: egui::Pos2) {
        let target = egui::pos2(player_pos.x, player_pos.y + PLAYER_SIZE[1]);
        let dx = (self.playlist_pos.x - target.x).abs();
        let dy = (self.playlist_pos.y - target.y).abs();
        if dx < SNAP_DIST && dy < SNAP_DIST {
            self.playlist_pos = target;
        }
    }
}

/// Check if `window_pos` is snapped to the bottom of a window at `anchor_pos` with `anchor_size`
fn is_snapped(window_pos: egui::Pos2, anchor_pos: egui::Pos2, anchor_size: [f32; 2]) -> bool {
    let expected = egui::pos2(anchor_pos.x, anchor_pos.y + anchor_size[1]);
    let dx = (window_pos.x - expected.x).abs();
    let dy = (window_pos.y - expected.y).abs();
    dx < SNAP_DIST * 2.0 && dy < SNAP_DIST * 2.0
}

// ── App State ─────────────────────────────────────────────────────────────────

pub struct AppState {
    pub show_settings: bool,
    pub settings_url: String,
    pub settings_user: String,
    pub settings_pass: String,
    pub settings_error: Option<String>,
    pub connecting: bool,

    pub client: Option<SubsonicClient>,

    audio: Option<AudioPlayer>,
    pub volume: f32,
    pub current_track: Option<Track>,
    pub playlist: Vec<Track>,
    pub playlist_index: Option<usize>,
    playing: bool,
    playback_start: Option<std::time::Instant>,
    playback_offset: u32, // seconds already played before current start

    pub lib_view: LibView,
    pub artists: Vec<Artist>,
    pub albums: Vec<Album>,
    pub tracks: Vec<Track>,
    pub selected_artist: Option<Artist>,
    pub selected_album: Option<Album>,
    pub search_query: String,
    pub search_results: Vec<Track>,
    pub loading: bool,

    async_rt: tokio::runtime::Runtime,
    rx: Arc<Mutex<Option<AsyncResult>>>,
}

enum AsyncResult {
    Connected(SubsonicClient),
    ConnectError(String),
    Artists(Vec<Artist>),
    Albums(Vec<Album>),
    Tracks(Vec<Track>),
    SearchResults(Vec<Track>),
}

impl AppState {
    fn new(audio: Option<AudioPlayer>) -> Self {
        let rt = tokio::runtime::Runtime::new().unwrap();
        let mut s = Self {
            show_settings: false,
            settings_url: String::new(),
            settings_user: String::new(),
            settings_pass: String::new(),
            settings_error: None,
            connecting: false,
            client: None,
            audio,
            volume: 0.8,
            current_track: None,
            playlist: Vec::new(),
            playlist_index: None,
            playing: false,
            playback_start: None,
            playback_offset: 0,
            lib_view: LibView::Artists,
            artists: Vec::new(),
            albums: Vec::new(),
            tracks: Vec::new(),
            selected_artist: None,
            selected_album: None,
            search_query: String::new(),
            search_results: Vec::new(),
            loading: false,
            async_rt: rt,
            rx: Arc::new(Mutex::new(None)),
        };
        s.load_saved_config();
        s
    }

    fn load_saved_config(&mut self) {
        if let Some(p) = config_path() {
            if let Ok(data) = std::fs::read_to_string(&p) {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&data) {
                    self.settings_url  = v["url"].as_str().unwrap_or("").to_string();
                    self.settings_user = v["user"].as_str().unwrap_or("").to_string();
                    self.settings_pass = v["pass"].as_str().unwrap_or("").to_string();
                    if !self.settings_url.is_empty() { self.try_connect(); }
                }
            }
        }
    }

    fn save_config(&self) {
        if let Some(p) = config_path() {
            let _ = std::fs::write(p, serde_json::json!({
                "url": self.settings_url, "user": self.settings_user, "pass": self.settings_pass
            }).to_string());
        }
    }

    pub fn try_connect(&mut self) {
        self.connecting = true;
        self.settings_error = None;
        let cfg = SubsonicConfig {
            server_url: self.settings_url.clone(),
            username:   self.settings_user.clone(),
            password:   self.settings_pass.clone(),
        };
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            let c = SubsonicClient::new(cfg);
            *rx.lock().unwrap() = Some(match c.ping().await {
                Ok(_)  => AsyncResult::Connected(c),
                Err(e) => AsyncResult::ConnectError(e.to_string()),
            });
        });
    }

    pub fn load_artists(&mut self) {
        let Some(c) = self.client.clone() else { return };
        self.loading = true;
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            *rx.lock().unwrap() = Some(match c.get_artists().await {
                Ok(a) => AsyncResult::Artists(a),
                Err(_) => AsyncResult::Artists(vec![]),
            });
        });
    }

    pub fn load_albums(&mut self, artist_id: String) {
        let Some(c) = self.client.clone() else { return };
        self.loading = true;
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            *rx.lock().unwrap() = Some(match c.get_artist(&artist_id).await {
                Ok(a) => AsyncResult::Albums(a),
                Err(_) => AsyncResult::Albums(vec![]),
            });
        });
    }

    pub fn load_tracks(&mut self, album_id: String) {
        let Some(c) = self.client.clone() else { return };
        self.loading = true;
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            *rx.lock().unwrap() = Some(match c.get_album(&album_id).await {
                Ok(t) => AsyncResult::Tracks(t),
                Err(_) => AsyncResult::Tracks(vec![]),
            });
        });
    }

    pub fn do_search(&mut self) {
        let Some(c) = self.client.clone() else { return };
        let q = self.search_query.clone();
        self.lib_view = LibView::Search;
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            *rx.lock().unwrap() = Some(match c.search(&q).await {
                Ok(t) => AsyncResult::SearchResults(t),
                Err(_) => AsyncResult::SearchResults(vec![]),
            });
        });
    }

    pub fn poll(&mut self, ctx: &egui::Context) {
        let result = self.rx.lock().unwrap().take();
        if let Some(r) = result {
            match r {
                AsyncResult::Connected(c) => {
                    self.client = Some(c);
                    self.connecting = false;
                    self.show_settings = false;
                    self.save_config();
                    self.load_artists();
                }
                AsyncResult::ConnectError(e) => {
                    self.connecting = false;
                    self.settings_error = Some(e);
                    self.show_settings = true;
                }
                AsyncResult::Artists(a)       => { self.artists = a;        self.loading = false; }
                AsyncResult::Albums(a)        => { self.albums = a;         self.loading = false; }
                AsyncResult::Tracks(t)        => { self.tracks = t;         self.loading = false; }
                AsyncResult::SearchResults(t) => { self.search_results = t; self.loading = false; }
            }
        }
        // Request repaint while playing (for time display update)
        if self.playing {
            ctx.request_repaint_after(std::time::Duration::from_millis(500));
        }
    }

    // ── Playback ──────────────────────────────────────────────────────────────

    pub fn play_tracks(&mut self, tracks: Vec<Track>, start: usize) {
        self.playlist = tracks;
        self.play_at_index(start);
    }

    pub fn enqueue_tracks(&mut self, tracks: Vec<Track>) {
        self.playlist.extend(tracks);
    }

    pub fn play_at_index(&mut self, idx: usize) {
        let Some(track) = self.playlist.get(idx).cloned() else { return };
        let Some(client) = &self.client else { return };
        let url = client.stream_url(&track.id);
        self.current_track = Some(track);
        self.playlist_index = Some(idx);
        self.playing = true;
        self.playback_start = Some(std::time::Instant::now());
        self.playback_offset = 0;
        if let Some(a) = &self.audio { let _ = a.play_url(&url); }
    }

    pub fn pause(&mut self) {
        if self.playing {
            self.playback_offset = self.elapsed_secs();
            self.playback_start = None;
            self.playing = false;
            if let Some(a) = &self.audio { a.pause(); }
        }
    }

    pub fn resume_or_play(&mut self) {
        if !self.playing {
            if self.current_track.is_some() {
                self.playing = true;
                self.playback_start = Some(std::time::Instant::now());
                if let Some(a) = &self.audio { a.resume(); }
            } else if !self.playlist.is_empty() {
                self.play_at_index(0);
            }
        }
    }

    pub fn stop(&mut self) {
        self.playing = false;
        self.playback_start = None;
        self.playback_offset = 0;
        self.current_track = None;
        if let Some(a) = &self.audio { a.stop(); }
    }

    pub fn next_track(&mut self) {
        if let Some(idx) = self.playlist_index {
            if idx + 1 < self.playlist.len() { self.play_at_index(idx + 1); }
        }
    }

    pub fn prev_track(&mut self) {
        if let Some(idx) = self.playlist_index {
            if idx > 0 { self.play_at_index(idx - 1); }
        }
    }

    pub fn seek(&mut self, t: f32) {
        if let Some(dur) = self.current_track.as_ref().and_then(|t| t.duration) {
            self.playback_offset = (t * dur as f32) as u32;
            self.playback_start = if self.playing { Some(std::time::Instant::now()) } else { None };
        }
    }

    pub fn is_playing(&self) -> bool { self.playing }

    pub fn set_volume(&mut self, v: f32) {
        self.volume = v;
        if let Some(a) = &self.audio { a.set_volume(v); }
    }

    pub fn elapsed_secs(&self) -> u32 {
        let running = self.playback_start
            .map(|s| s.elapsed().as_secs() as u32)
            .unwrap_or(0);
        self.playback_offset + running
    }
}

fn config_path() -> Option<std::path::PathBuf> {
    let dir = dirs::config_dir()?.join("hagtamp");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("config.json"))
}
