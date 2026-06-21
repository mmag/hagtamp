mod player;
mod skin;
mod ui;

use anyhow::Result;
use eframe::egui;
use player::{Album, Artist, AudioPlayer, SubsonicClient, SubsonicConfig, Track};
use std::sync::{Arc, Mutex};
use ui::library::LibView;

fn main() -> Result<(), eframe::Error> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("hagtamp")
            .with_inner_size([800.0, 600.0])
            .with_min_inner_size([600.0, 400.0]),
        ..Default::default()
    };

    eframe::run_native(
        "hagtamp",
        options,
        Box::new(|_cc| Ok(Box::new(App::new()))),
    )
}

struct App {
    state: AppState,
}

impl App {
    fn new() -> Self {
        let audio = AudioPlayer::new().ok();
        Self {
            state: AppState::new(audio),
        }
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        ctx.set_visuals(egui::Visuals::dark());
        let state = &mut self.state;
        state.poll();

        if state.show_settings || state.client.is_none() {
            ui::settings::show(ctx, state);
        }

        if state.client.is_some() {
            ui::player_window::show(ctx, state);
            ui::playlist::show(ctx, state);
            ui::library::show(ctx, state);
        }
    }
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
                    if !self.settings_url.is_empty() {
                        self.try_connect();
                    }
                }
            }
        }
    }

    fn save_config(&self) {
        if let Some(p) = config_path() {
            let _ = std::fs::write(p, serde_json::json!({
                "url": self.settings_url,
                "user": self.settings_user,
                "pass": self.settings_pass,
            }).to_string());
        }
    }

    pub fn try_connect(&mut self) {
        self.connecting = true;
        self.settings_error = None;
        let config = SubsonicConfig {
            server_url: self.settings_url.clone(),
            username: self.settings_user.clone(),
            password: self.settings_pass.clone(),
        };
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            let client = SubsonicClient::new(config);
            let result = match client.ping().await {
                Ok(_)  => AsyncResult::Connected(client),
                Err(e) => AsyncResult::ConnectError(e.to_string()),
            };
            *rx.lock().unwrap() = Some(result);
        });
    }

    pub fn load_artists(&mut self) {
        let Some(client) = self.client.clone() else { return };
        self.loading = true;
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            let r = match client.get_artists().await {
                Ok(a) => AsyncResult::Artists(a),
                Err(_) => AsyncResult::Artists(vec![]),
            };
            *rx.lock().unwrap() = Some(r);
        });
    }

    pub fn load_albums(&mut self, artist_id: String) {
        let Some(client) = self.client.clone() else { return };
        self.loading = true;
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            let r = match client.get_artist(&artist_id).await {
                Ok(a) => AsyncResult::Albums(a),
                Err(_) => AsyncResult::Albums(vec![]),
            };
            *rx.lock().unwrap() = Some(r);
        });
    }

    pub fn load_tracks(&mut self, album_id: String) {
        let Some(client) = self.client.clone() else { return };
        self.loading = true;
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            let r = match client.get_album(&album_id).await {
                Ok(t) => AsyncResult::Tracks(t),
                Err(_) => AsyncResult::Tracks(vec![]),
            };
            *rx.lock().unwrap() = Some(r);
        });
    }

    pub fn do_search(&mut self) {
        let Some(client) = self.client.clone() else { return };
        let query = self.search_query.clone();
        self.lib_view = LibView::Search;
        let rx = self.rx.clone();
        self.async_rt.spawn(async move {
            let r = match client.search(&query).await {
                Ok(t) => AsyncResult::SearchResults(t),
                Err(_) => AsyncResult::SearchResults(vec![]),
            };
            *rx.lock().unwrap() = Some(r);
        });
    }

    pub fn poll(&mut self) {
        let result = self.rx.lock().unwrap().take();
        if let Some(r) = result {
            match r {
                AsyncResult::Connected(client) => {
                    self.client = Some(client);
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
    }

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
        if let Some(audio) = &self.audio {
            let _ = audio.play_url(&url);
        }
    }

    pub fn pause(&mut self) {
        self.playing = false;
        if let Some(a) = &self.audio { a.pause(); }
    }

    pub fn resume_or_play(&mut self) {
        if self.current_track.is_some() {
            self.playing = true;
            if let Some(a) = &self.audio { a.resume(); }
        } else if !self.playlist.is_empty() {
            self.play_at_index(0);
        }
    }

    pub fn stop(&mut self) {
        self.playing = false;
        self.current_track = None;
        if let Some(a) = &self.audio { a.stop(); }
    }

    pub fn next_track(&mut self) {
        if let Some(idx) = self.playlist_index {
            let next = idx + 1;
            if next < self.playlist.len() {
                self.play_at_index(next);
            }
        }
    }

    pub fn prev_track(&mut self) {
        if let Some(idx) = self.playlist_index {
            if idx > 0 { self.play_at_index(idx - 1); }
        }
    }

    pub fn is_playing(&self) -> bool { self.playing }

    pub fn set_volume(&mut self, v: f32) {
        self.volume = v;
        if let Some(a) = &self.audio { a.set_volume(v); }
    }

    pub fn open_skin_picker(&self) {
        // TODO: integrate rfd file dialog
    }
}

fn config_path() -> Option<std::path::PathBuf> {
    let dir = dirs::config_dir()?.join("hagtamp");
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir.join("config.json"))
}
