use egui::{Color32, Rect, ScrollArea, Vec2};
use crate::skin::{SkinTextures, sprite_uv};
use crate::AppState;

const PL_W: f32 = 275.0;
const PL_TITLEBAR_H: f32 = 20.0;

pub fn render(ui: &mut egui::Ui, skin: &SkinTextures, state: &mut AppState) {
    let origin = ui.min_rect().min;
    let size = ui.available_size();
    let painter = ui.painter();

    // Draw PLEDIT.BMP as background (tile if needed)
    let bg_rect = Rect::from_min_size(origin, size);
    let [pw, ph] = skin.pledit.size();
    // PLEDIT.BMP has a top section (~21px) and bottom section, tiled body
    // For simplicity: tile the full bitmap
    painter.image(
        skin.pledit.id(), bg_rect,
        egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)),
        Color32::WHITE,
    );

    // Titlebar drag
    let tb_rect = Rect::from_min_size(origin, Vec2::new(size.x, PL_TITLEBAR_H));
    if ui.interact(tb_rect, ui.id().with("pl_tb"), egui::Sense::drag()).dragged() {
        ui.ctx().send_viewport_cmd(egui::ViewportCommand::StartDrag);
    }
    // Close
    let close = Rect::from_min_size(
        egui::pos2(origin.x + size.x - 18.0, origin.y),
        Vec2::new(18.0, PL_TITLEBAR_H),
    );
    if ui.interact(close, ui.id().with("pl_close"), egui::Sense::click()).clicked() {
        ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
    }

    // Track list area
    let list_rect = Rect::from_min_max(
        egui::pos2(origin.x + 4.0, origin.y + PL_TITLEBAR_H + 2.0),
        egui::pos2(origin.x + size.x - 4.0, origin.y + size.y - 20.0),
    );
    ui.allocate_ui_at_rect(list_rect, |ui| {
        ScrollArea::vertical().show(ui, |ui| {
            let playlist = state.playlist.clone();
            let current = state.playlist_index;
            for (i, track) in playlist.iter().enumerate() {
                let is_current = current == Some(i);
                let label = format!("{}. {} — {}", i + 1, track.artist, track.title);
                let resp = ui.selectable_label(is_current, &label);
                if resp.double_clicked() {
                    state.play_at_index(i);
                }
            }
            if state.playlist.is_empty() {
                ui.colored_label(Color32::from_rgb(0x00, 0xb4, 0x00), "Playlist empty");
            }
        });
    });
}

pub fn render_plain(ui: &mut egui::Ui, state: &mut AppState) {
    ScrollArea::vertical().show(ui, |ui| {
        let playlist = state.playlist.clone();
        for (i, track) in playlist.iter().enumerate() {
            let label = format!("{}. {} — {}", i + 1, track.artist, track.title);
            if ui.selectable_label(state.playlist_index == Some(i), &label)
                .double_clicked()
            {
                state.play_at_index(i);
            }
        }
    });
}
