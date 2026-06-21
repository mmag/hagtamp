use anyhow::Result;
use egui::{ColorImage, Context, TextureHandle, TextureOptions};
use std::collections::HashMap;
use std::io::Read;
use zip::ZipArchive;

pub struct SkinTextures {
    pub main: TextureHandle,
    pub cbuttons: TextureHandle,
    pub numbers: TextureHandle,
    pub titlebar: TextureHandle,
    pub posbar: TextureHandle,
    pub volume: TextureHandle,
    pub balance: TextureHandle,
    pub shufrep: TextureHandle,
    pub playpaus: TextureHandle,
    pub monoster: TextureHandle,
    pub pledit: TextureHandle,
    pub eqmain: TextureHandle,
}

impl SkinTextures {
    pub fn load(ctx: &Context, path: &std::path::Path) -> Result<Self> {
        let file = std::fs::File::open(path)?;
        let mut archive = ZipArchive::new(file)?;
        let mut map: HashMap<String, Vec<u8>> = HashMap::new();

        for i in 0..archive.len() {
            let mut entry = archive.by_index(i)?;
            let name = entry.name().to_uppercase();
            let base = name.split('/').last().unwrap_or(&name).to_string();
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf)?;
            map.insert(base, buf);
        }

        let load = |name: &str| -> TextureHandle {
            let bytes = map.get(name).expect(&format!("skin missing {}", name));
            let img = image::load_from_memory(bytes)
                .expect(&format!("failed to decode {}", name))
                .into_rgba8();
            let (w, h) = img.dimensions();
            let pixels: Vec<egui::Color32> = img.pixels()
                .map(|p| egui::Color32::from_rgba_unmultiplied(p[0], p[1], p[2], p[3]))
                .collect();
            ctx.load_texture(
                name,
                ColorImage { size: [w as usize, h as usize], pixels },
                TextureOptions::NEAREST,
            )
        };

        Ok(Self {
            main:     load("MAIN.BMP"),
            cbuttons: load("CBUTTONS.BMP"),
            numbers:  load("NUMBERS.BMP"),
            titlebar: load("TITLEBAR.BMP"),
            posbar:   load("POSBAR.BMP"),
            volume:   load("VOLUME.BMP"),
            balance:  load("BALANCE.BMP"),
            shufrep:  load("SHUFREP.BMP"),
            playpaus: load("PLAYPAUS.BMP"),
            monoster: load("MONOSTER.BMP"),
            pledit:   load("PLEDIT.BMP"),
            eqmain:   load("EQMAIN.BMP"),
        })
    }
}

/// Return UV rect for a sprite at pixel (x,y)-(x+w,y+h) within a texture of size (tw,th)
pub fn sprite_uv(tx: f32, ty: f32, tw: f32, th: f32, sw: f32, sh: f32) -> egui::Rect {
    egui::Rect::from_min_max(
        egui::pos2(tx / tw, ty / th),
        egui::pos2((tx + sw) / tw, (ty + sh) / th),
    )
}
