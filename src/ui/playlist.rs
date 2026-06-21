use egui::{Context, ScrollArea, Window};

use crate::AppState;
use crate::player::subsonic::Track;

pub fn show(ctx: &Context, state: &mut AppState) {
    Window::new("WINAMP PLAYLIST")
        .default_pos([20.0, 200.0])
        .default_size([275.0, 200.0])
        .resizable(true)
        .show(ctx, |ui| {
            ScrollArea::vertical().show(ui, |ui| {
                ui.set_width(ui.available_width());
                let playlist: Vec<Track> = state.playlist.clone();
                let current_idx = state.playlist_index;

                for (i, track) in playlist.iter().enumerate() {
                    let is_current = current_idx == Some(i);
                    let label = format!("{}. {} — {}", i + 1, track.artist, track.title);
                    if ui.selectable_label(is_current, label).double_clicked() {
                        state.play_at_index(i);
                    }
                }

                if state.playlist.is_empty() {
                    ui.label("Playlist is empty. Add tracks from the library.");
                }
            });
        });
}
