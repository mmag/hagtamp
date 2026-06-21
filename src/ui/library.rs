use egui::{Context, ScrollArea, Window};

use crate::player::subsonic::{Album, Artist, Track};
use crate::AppState;

pub fn show(ctx: &Context, state: &mut AppState) {
    let screen = ctx.screen_rect();
    Window::new("MEDIA LIBRARY")
        .default_pos([screen.max.x - 390.0, 20.0])
        .default_size([370.0, 500.0])
        .resizable(true)
        .title_bar(true)
        .show(ctx, |ui| {
            // Search bar
            ui.horizontal(|ui| {
                ui.label("🔍");
                let resp = ui.text_edit_singleline(&mut state.search_query);
                if resp.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                    state.do_search();
                }
                if ui.button("Go").clicked() {
                    state.do_search();
                }
            });

            ui.separator();

            // Nav breadcrumb
            ui.horizontal(|ui| {
                if ui.selectable_label(state.lib_view == LibView::Artists, "Artists").clicked() {
                    state.lib_view = LibView::Artists;
                    state.selected_artist = None;
                    state.selected_album = None;
                }
                if let Some(artist) = &state.selected_artist.clone() {
                    ui.label("›");
                    if ui.selectable_label(
                        state.lib_view == LibView::Albums,
                        &artist.name
                    ).clicked() {
                        state.lib_view = LibView::Albums;
                        state.selected_album = None;
                    }
                }
                if let Some(album) = &state.selected_album.clone() {
                    ui.label("›");
                    ui.label(&album.name);
                }
            });

            ui.separator();

            match state.lib_view {
                LibView::Artists => show_artists(ui, state),
                LibView::Albums  => show_albums(ui, state),
                LibView::Tracks  => show_tracks(ui, state),
                LibView::Search  => show_search_results(ui, state),
            }
        });
}

#[derive(PartialEq, Clone)]
pub enum LibView {
    Artists,
    Albums,
    Tracks,
    Search,
}

fn show_artists(ui: &mut egui::Ui, state: &mut AppState) {
    let artists: Vec<Artist> = state.artists.clone();
    ScrollArea::vertical().show(ui, |ui| {
        ui.set_width(ui.available_width());
        for artist in &artists {
            let sel = state.selected_artist.as_ref().map(|a: &Artist| a.id == artist.id).unwrap_or(false);
            if ui.selectable_label(sel, &artist.name).double_clicked() {
                state.selected_artist = Some(artist.clone());
                state.lib_view = LibView::Albums;
                state.load_albums(artist.id.clone());
            }
            if ui.selectable_label(sel, "").clicked() {
                // single click just selects
            }
        }
        if artists.is_empty() {
            if state.loading {
                ui.spinner();
            } else {
                ui.label("No artists loaded.");
            }
        }
    });
}

fn show_albums(ui: &mut egui::Ui, state: &mut AppState) {
    let albums: Vec<Album> = state.albums.clone();
    ScrollArea::vertical().show(ui, |ui| {
        ui.set_width(ui.available_width());
        for album in &albums {
            let label = if let Some(y) = album.year {
                format!("[{}] {}", y, album.name)
            } else {
                album.name.clone()
            };
            if ui.selectable_label(false, label).double_clicked() {
                state.selected_album = Some(album.clone());
                state.lib_view = LibView::Tracks;
                state.load_tracks(album.id.clone());
            }
        }
        if albums.is_empty() && state.loading {
            ui.spinner();
        }
    });
}

fn show_tracks(ui: &mut egui::Ui, state: &mut AppState) {
    let tracks: Vec<Track> = state.tracks.clone();

    ui.horizontal(|ui| {
        if ui.button("▶ Play all").clicked() {
            state.play_tracks(tracks.clone(), 0);
        }
        if ui.button("+ Enqueue all").clicked() {
            state.enqueue_tracks(tracks.clone());
        }
    });
    ui.separator();

    ScrollArea::vertical().show(ui, |ui| {
        ui.set_width(ui.available_width());
        for (i, track) in tracks.iter().enumerate() {
            let label = format!(
                "{}. {} ({})",
                track.track.unwrap_or(i as u32 + 1),
                track.title,
                fmt_duration(track.duration)
            );
            if ui.selectable_label(
                state.current_track.as_ref().map(|t: &Track| t.id == track.id).unwrap_or(false),
                label
            ).double_clicked() {
                state.play_tracks(tracks.clone(), i);
            }
        }
        if tracks.is_empty() && state.loading {
            ui.spinner();
        }
    });
}

fn show_search_results(ui: &mut egui::Ui, state: &mut AppState) {
    let tracks: Vec<Track> = state.search_results.clone();
    ScrollArea::vertical().show(ui, |ui| {
        ui.set_width(ui.available_width());
        for (i, track) in tracks.iter().enumerate() {
            let label = format!("{} — {}", track.artist, track.title);
            if ui.selectable_label(false, label).double_clicked() {
                state.play_tracks(tracks.clone(), i);
            }
        }
        if tracks.is_empty() {
            ui.label("No results.");
        }
    });
}

fn fmt_duration(secs: Option<u32>) -> String {
    let s = secs.unwrap_or(0);
    format!("{}:{:02}", s / 60, s % 60)
}
