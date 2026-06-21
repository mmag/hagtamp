pub mod subsonic;

use anyhow::Result;
use rodio::{Decoder, OutputStream, OutputStreamHandle, Sink};
use std::io::BufReader;
use std::sync::{Arc, Mutex};

pub use subsonic::{Album, Artist, SubsonicClient, SubsonicConfig, Track};

pub struct AudioPlayer {
    _stream: OutputStream,
    handle: OutputStreamHandle,
    sink: Arc<Mutex<Option<Sink>>>,
}

impl AudioPlayer {
    pub fn new() -> Result<Self> {
        let (stream, handle) = OutputStream::try_default()?;
        Ok(Self {
            _stream: stream,
            handle,
            sink: Arc::new(Mutex::new(None)),
        })
    }

    pub fn play_url(&self, url: &str) -> Result<()> {
        let response = reqwest::blocking::get(url)?;
        let cursor = std::io::Cursor::new(response.bytes()?);
        let source = Decoder::new(BufReader::new(cursor))?;
        let sink = Sink::try_new(&self.handle)?;
        sink.append(source);
        *self.sink.lock().unwrap() = Some(sink);
        Ok(())
    }

    pub fn pause(&self) {
        if let Some(s) = self.sink.lock().unwrap().as_ref() {
            s.pause();
        }
    }

    pub fn resume(&self) {
        if let Some(s) = self.sink.lock().unwrap().as_ref() {
            s.play();
        }
    }

    pub fn stop(&self) {
        if let Some(s) = self.sink.lock().unwrap().as_ref() {
            s.stop();
        }
    }

    pub fn set_volume(&self, v: f32) {
        if let Some(s) = self.sink.lock().unwrap().as_ref() {
            s.set_volume(v);
        }
    }

    pub fn is_paused(&self) -> bool {
        self.sink.lock().unwrap().as_ref().map(|s| s.is_paused()).unwrap_or(true)
    }

    pub fn is_stopped(&self) -> bool {
        self.sink.lock().unwrap().as_ref().map(|s| s.empty()).unwrap_or(true)
    }
}
