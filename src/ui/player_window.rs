/// Winamp-accurate player window rendering from skin sprites.
use egui::{Painter, Pos2, Rect, Vec2, Color32};
use crate::skin::{SkinTextures, sprite_uv};
use crate::AppState;

// Winamp 2.x classic layout constants (pixels in MAIN.BMP)
const PLAYER_W: f32 = 275.0;
const PLAYER_H: f32 = 116.0;

// CBUTTONS.BMP: 6 buttons × 2 rows (normal/pressed), each 22×18
const BTN_W: f32 = 22.0;
const BTN_H: f32 = 18.0;
// Positions in MAIN.BMP where buttons are drawn
const BTN_PREV_X:  f32 = 16.0;
const BTN_PLAY_X:  f32 = 39.0;
const BTN_PAUSE_X: f32 = 62.0;
const BTN_STOP_X:  f32 = 85.0;
const BTN_NEXT_X:  f32 = 108.0;
const BTN_Y:       f32 = 88.0;

// NUMBERS.BMP: digits 0-9 are 9×13 each, then minus(-) and colon(:)
const NUM_W: f32 = 9.0;
const NUM_H: f32 = 13.0;
const TIME_X: f32 = 48.0;  // position of time display in MAIN.BMP
const TIME_Y: f32 = 26.0;

// Volume slider: position in MAIN.BMP, slider is in VOLUME.BMP
const VOL_X: f32 = 107.0;
const VOL_Y: f32 = 57.0;
const VOL_W: f32 = 68.0;
const VOL_H: f32 = 13.0;

// Position bar
const POS_X: f32 = 16.0;
const POS_Y: f32 = 72.0;
const POS_W: f32 = 248.0;
const POS_H: f32 = 10.0;

pub fn render(ui: &mut egui::Ui, skin: &SkinTextures, state: &mut AppState) {
    let origin = ui.min_rect().min;
    let painter = ui.painter();

    // 1. Draw MAIN.BMP as background (full 275×116)
    let bg_rect = Rect::from_min_size(origin, Vec2::new(PLAYER_W, PLAYER_H));
    painter.image(
        skin.main.id(), bg_rect,
        egui::Rect::from_min_max(egui::pos2(0.0, 0.0), egui::pos2(1.0, 1.0)),
        Color32::WHITE,
    );

    // 2. Title bar drag region (top 14px)
    let titlebar_rect = Rect::from_min_size(origin, Vec2::new(PLAYER_W, 14.0));
    let tb_resp = ui.interact(titlebar_rect, ui.id().with("drag"), egui::Sense::drag());
    if tb_resp.dragged() {
        ui.ctx().send_viewport_cmd(egui::ViewportCommand::StartDrag);
    }

    // Close button (top-right, ≈ 18×18)
    let close_rect = Rect::from_min_size(
        Pos2::new(origin.x + PLAYER_W - 18.0, origin.y),
        Vec2::new(18.0, 14.0),
    );
    if ui.interact(close_rect, ui.id().with("close"), egui::Sense::click()).clicked() {
        ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
    }

    // 3. Time display from NUMBERS.BMP
    let elapsed = state.elapsed_secs();
    let mins = elapsed / 60;
    let secs = elapsed % 60;
    let digits = [mins / 10, mins % 10, 10u32 /* colon */, secs / 10, secs % 10];
    let [nw, nh] = skin.numbers.size();
    for (i, &digit) in digits.iter().enumerate() {
        let x_offset = if i >= 2 { 2.0 } else { 0.0 }; // tighter colon spacing
        let dest = Rect::from_min_size(
            Pos2::new(origin.x + TIME_X + i as f32 * (NUM_W + 1.0) + x_offset, origin.y + TIME_Y),
            Vec2::new(NUM_W, NUM_H),
        );
        let uv = sprite_uv(digit as f32 * NUM_W, 0.0, nw as f32, nh as f32, NUM_W, NUM_H);
        painter.image(skin.numbers.id(), dest, uv, Color32::WHITE);
    }

    // 4. Control buttons from CBUTTONS.BMP
    let [cw, ch] = skin.cbuttons.size();
    let buttons = [
        (BTN_PREV_X,  0u32,  "prev"),
        (BTN_PLAY_X,  1,     "play"),
        (BTN_PAUSE_X, 2,     "pause"),
        (BTN_STOP_X,  3,     "stop"),
        (BTN_NEXT_X,  4,     "next"),
    ];
    for &(bx, idx, id) in &buttons {
        let dest = Rect::from_min_size(
            Pos2::new(origin.x + bx, origin.y + BTN_Y),
            Vec2::new(BTN_W, BTN_H),
        );
        let resp = ui.interact(dest, ui.id().with(id), egui::Sense::click());
        // pressed row = y offset 18 in CBUTTONS.BMP
        let row_y = if resp.is_pointer_button_down_on() { BTN_H } else { 0.0 };
        let uv = sprite_uv(idx as f32 * BTN_W, row_y, cw as f32, ch as f32, BTN_W, BTN_H);
        painter.image(skin.cbuttons.id(), dest, uv, Color32::WHITE);

        if resp.clicked() {
            match id {
                "prev"  => state.prev_track(),
                "play"  => state.resume_or_play(),
                "pause" => state.pause(),
                "stop"  => state.stop(),
                "next"  => state.next_track(),
                _ => {}
            }
        }
    }

    // 5. Volume slider (drag to set volume)
    let vol_dest = Rect::from_min_size(
        Pos2::new(origin.x + VOL_X, origin.y + VOL_Y),
        Vec2::new(VOL_W, VOL_H),
    );
    let vol_resp = ui.interact(vol_dest, ui.id().with("vol"), egui::Sense::drag());
    if vol_resp.dragged() {
        if let Some(pos) = vol_resp.interact_pointer_pos() {
            let t = ((pos.x - vol_dest.min.x) / vol_dest.width()).clamp(0.0, 1.0);
            state.set_volume(t);
        }
    }
    // Draw volume knob from VOLUME.BMP (28 frames of 15×11 at row=0)
    let [vw, vh] = skin.volume.size();
    let vol_frame = (state.volume * 27.0).round() as u32;
    let vol_knob_uv = sprite_uv(0.0, vol_frame as f32 * 15.0, vw as f32, vh as f32, 68.0, 13.0);
    painter.image(skin.volume.id(), vol_dest, vol_knob_uv, Color32::WHITE);

    // 6. Position bar
    let pos_dest = Rect::from_min_size(
        Pos2::new(origin.x + POS_X, origin.y + POS_Y),
        Vec2::new(POS_W, POS_H),
    );
    let pos_resp = ui.interact(pos_dest, ui.id().with("posbar"), egui::Sense::drag());
    if pos_resp.dragged() {
        if let Some(p) = pos_resp.interact_pointer_pos() {
            let t = ((p.x - pos_dest.min.x) / pos_dest.width()).clamp(0.0, 1.0);
            state.seek(t);
        }
    }
    // Draw position bar from POSBAR.BMP
    let [pw, ph] = skin.posbar.size();
    let pos_uv = sprite_uv(0.0, 0.0, pw as f32, ph as f32, pw as f32, (ph / 2) as f32);
    painter.image(skin.posbar.id(), pos_dest, pos_uv, Color32::WHITE);

    // 7. Track title (scrolling would be nice later)
    if let Some(track) = &state.current_track.clone() {
        // Draw into the title area of MAIN.BMP (roughly y=27..39 on the right side)
        let title = format!("{} — {}", track.artist, track.title);
        painter.text(
            Pos2::new(origin.x + 112.0, origin.y + 28.0),
            egui::Align2::LEFT_TOP,
            &title,
            egui::FontId::monospace(8.0),
            Color32::from_rgb(0x1A, 0xFF, 0x1A),
        );
    }

    // Settings button (bottom right of player)
    let cfg_rect = Rect::from_min_size(
        Pos2::new(origin.x + PLAYER_W - 20.0, origin.y + PLAYER_H - 16.0),
        Vec2::new(18.0, 14.0),
    );
    if ui.interact(cfg_rect, ui.id().with("cfg"), egui::Sense::click()).clicked() {
        state.show_settings = true;
    }
}
