/// Winamp main player window rendered with skin sprites.
/// Falls back to a plain egui panel if no skin is loaded.
use egui::{Context, Window};

use crate::AppState;

pub fn show(ctx: &Context, state: &mut AppState) {
    Window::new("WINAMP")
        .resizable(false)
        .default_pos([20.0, 20.0])
        .title_bar(true)
        .show(ctx, |ui| {
            // Track info
            let title = state.current_track.as_ref()
                .map(|t| format!("{} — {}", t.artist, t.title))
                .unwrap_or_else(|| "Hagtamp".into());
            ui.label(egui::RichText::new(&title).monospace().size(11.0));

            ui.separator();

            // Transport controls
            ui.horizontal(|ui| {
                if ui.button("⏮").clicked() { state.prev_track(); }
                if state.is_playing() {
                    if ui.button("⏸").clicked() { state.pause(); }
                } else {
                    if ui.button("▶").clicked() { state.resume_or_play(); }
                }
                if ui.button("⏹").clicked() { state.stop(); }
                if ui.button("⏭").clicked() { state.next_track(); }
            });

            ui.separator();

            // Volume
            ui.horizontal(|ui| {
                ui.label("VOL");
                let mut vol = state.volume;
                if ui.add(egui::Slider::new(&mut vol, 0.0f32..=1.0).show_value(false)).changed() {
                    state.set_volume(vol);
                }
            });

            // Skin switcher
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                if ui.small_button("🎨 Skin…").clicked() {
                    state.open_skin_picker();
                }
                if ui.small_button("⚙").clicked() {
                    state.show_settings = true;
                }
            });
        });
}
