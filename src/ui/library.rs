use egui::{Context, ScrollArea};
use crate::player::subsonic::{Album, Artist, Track};
use crate::AppState;

#[derive(PartialEq, Clone)]
pub enum LibView { Artists, Albums, Tracks, Search }

pub fn show(ctx: &Context, ui: &mut egui::Ui, state: &mut AppState) {
    // Search bar
    ui.horizontal(|ui| {
        ui.label("🔍");
        let r = ui.text_edit_singleline(&mut state.search_query);
        if r.lost_focus() && ctx.input(|i| i.key_pressed(egui::Key::Enter)) {
            state.do_search();
        }
        if ui.button("Go").clicked() { state.do_search(); }
    });
    ui.separator();

    // Breadcrumb nav
    ui.horizontal(|ui| {
        if ui.selectable_label(state.lib_view == LibView::Artists, "Artists").clicked() {
            state.lib_view = LibView::Artists;
            state.selected_artist = None;
            state.selected_album = None;
        }
        if let Some(a) = state.selected_artist.clone() {
            ui.label("›");
            if ui.selectable_label(state.lib_view == LibView::Albums, &a.name).clicked() {
                state.lib_view = LibView::Albums;
                state.selected_album = None;
            }
        }
        if let Some(a) = state.selected_album.clone() {
            ui.label("›");
            ui.label(&a.name);
        }
    });
    ui.separator();

    match state.lib_view {
        LibView::Artists => artists(ui, state),
        LibView::Albums  => albums(ui, state),
        LibView::Tracks  => tracks(ui, state),
        LibView::Search  => search(ui, state),
    }
}

fn artists(ui: &mut egui::Ui, state: &mut AppState) {
    ScrollArea::vertical().show(ui, |ui| {
        ui.set_width(ui.available_width());
        if state.loading { ui.spinner(); return; }
        for artist in state.artists.clone() {
            let sel = state.selected_artist.as_ref().map(|a: &Artist| a.id == artist.id).unwrap_or(false);
            if ui.selectable_label(sel, &artist.name).double_clicked() {
                let id = artist.id.clone();
                state.selected_artist = Some(artist);
                state.lib_view = LibView::Albums;
                state.load_albums(id);
            }
        }
    });
}

fn albums(ui: &mut egui::Ui, state: &mut AppState) {
    ScrollArea::vertical().show(ui, |ui| {
        ui.set_width(ui.available_width());
        if state.loading { ui.spinner(); return; }
        for album in state.albums.clone() {
            let label = match album.year {
                Some(y) => format!("[{}] {}", y, album.name),
                None    => album.name.clone(),
            };
            if ui.selectable_label(false, label).double_clicked() {
                let id = album.id.clone();
                state.selected_album = Some(album);
                state.lib_view = LibView::Tracks;
                state.load_tracks(id);
            }
        }
    });
}

fn tracks(ui: &mut egui::Ui, state: &mut AppState) {
    ui.horizontal(|ui| {
        if ui.button("▶ Play all").clicked() {
            let t = state.tracks.clone();
            state.play_tracks(t, 0);
        }
        if ui.button("+ Enqueue all").clicked() {
            let t = state.tracks.clone();
            state.enqueue_tracks(t);
        }
    });
    ui.separator();

    ScrollArea::vertical().show(ui, |ui| {
        ui.set_width(ui.available_width());
        if state.loading { ui.spinner(); return; }
        for (i, track) in state.tracks.clone().iter().enumerate() {
            let dur = track.duration.map(|s| format!("{}:{:02}", s/60, s%60)).unwrap_or_default();
            let label = format!("{}. {} ({})", track.track.unwrap_or(i as u32 + 1), track.title, dur);
            let is_cur = state.current_track.as_ref().map(|t: &Track| t.id == track.id).unwrap_or(false);
            if ui.selectable_label(is_cur, label).double_clicked() {
                let tracks = state.tracks.clone();
                state.play_tracks(tracks, i);
            }
        }
    });
}

fn search(ui: &mut egui::Ui, state: &mut AppState) {
    ScrollArea::vertical().show(ui, |ui| {
        ui.set_width(ui.available_width());
        for (i, track) in state.search_results.clone().iter().enumerate() {
            let label = format!("{} — {}", track.artist, track.title);
            if ui.selectable_label(false, label).double_clicked() {
                let tracks = state.search_results.clone();
                state.play_tracks(tracks, i);
            }
        }
        if state.search_results.is_empty() { ui.label("No results"); }
    });
}
