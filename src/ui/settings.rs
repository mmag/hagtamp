use egui::{Context, Window};

use crate::AppState;

pub fn show(ctx: &Context, state: &mut AppState) {
    Window::new("⚙  Connect to Navidrome")
        .resizable(false)
        .collapsible(false)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .show(ctx, |ui| {
            egui::Grid::new("settings_grid")
                .num_columns(2)
                .spacing([8.0, 6.0])
                .show(ui, |ui| {
                    ui.label("Server URL:");
                    ui.text_edit_singleline(&mut state.settings_url);
                    ui.end_row();

                    ui.label("Username:");
                    ui.text_edit_singleline(&mut state.settings_user);
                    ui.end_row();

                    ui.label("Password:");
                    ui.add(egui::TextEdit::singleline(&mut state.settings_pass).password(true));
                    ui.end_row();
                });

            ui.add_space(8.0);

            if let Some(err) = &state.settings_error.clone() {
                ui.colored_label(egui::Color32::RED, err);
                ui.add_space(4.0);
            }

            ui.horizontal(|ui| {
                let connecting = state.connecting;
                let btn = ui.add_enabled(!connecting, egui::Button::new(
                    if connecting { "Connecting…" } else { "Connect" }
                ));
                if btn.clicked() {
                    state.try_connect();
                }
            });
        });
}
