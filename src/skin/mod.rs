use anyhow::Result;
use egui::ColorImage;
use std::collections::HashMap;
use std::io::Read;
use zip::ZipArchive;

/// Names of BMP files inside a .wsz skin
pub const SKIN_FILES: &[&str] = &[
    "MAIN.BMP",
    "CBUTTONS.BMP",
    "TITLEBAR.BMP",
    "SHUFREP.BMP",
    "VOLUME.BMP",
    "BALANCE.BMP",
    "NUMBERS.BMP",
    "PLAYPAUS.BMP",
    "POSBAR.BMP",
    "MONOSTER.BMP",
    "EQ_MAIN.BMP",
    "EQ_EX.BMP",
    "PLEDIT.BMP",
    "AVISM.BMP",
];

pub struct Skin {
    pub images: HashMap<String, ColorImage>,
}

impl Skin {
    /// Load a .wsz file (ZIP archive containing BMP files)
    pub fn load_wsz(path: &std::path::Path) -> Result<Self> {
        let file = std::fs::File::open(path)?;
        let mut archive = ZipArchive::new(file)?;
        let mut images = HashMap::new();

        for i in 0..archive.len() {
            let mut entry = archive.by_index(i)?;
            let name = entry.name().to_uppercase();
            // Strip path prefix if any
            let base = name.split('/').last().unwrap_or(&name).to_string();

            if SKIN_FILES.contains(&base.as_str()) {
                let mut buf = Vec::new();
                entry.read_to_end(&mut buf)?;
                if let Ok(img) = load_bmp_rgba(&buf) {
                    images.insert(base, img);
                }
            }
        }

        Ok(Self { images })
    }

    pub fn get(&self, name: &str) -> Option<&ColorImage> {
        self.images.get(&name.to_uppercase())
    }
}

fn load_bmp_rgba(data: &[u8]) -> Result<ColorImage> {
    let img = image::load_from_memory_with_format(data, image::ImageFormat::Bmp)?
        .into_rgba8();
    let (w, h) = img.dimensions();
    let pixels: Vec<egui::Color32> = img
        .pixels()
        .map(|p| egui::Color32::from_rgba_unmultiplied(p[0], p[1], p[2], p[3]))
        .collect();
    Ok(ColorImage {
        size: [w as usize, h as usize],
        pixels,
    })
}
