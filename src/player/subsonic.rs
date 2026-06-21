use anyhow::{anyhow, Result};
use serde::Deserialize;

#[derive(Clone, Debug)]
pub struct SubsonicConfig {
    pub server_url: String,
    pub username: String,
    pub password: String,
}

#[derive(Clone, Debug)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub album_count: u32,
}

#[derive(Clone, Debug)]
pub struct Album {
    pub id: String,
    pub name: String,
    pub artist: String,
    pub artist_id: String,
    pub year: Option<u32>,
    pub cover_art: Option<String>,
    pub song_count: u32,
}

#[derive(Clone, Debug)]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub track: Option<u32>,
    pub duration: Option<u32>,
    pub cover_art: Option<String>,
}

// ── Raw Subsonic JSON types ──────────────────────────────────────────────────

#[derive(Deserialize)]
struct SubsonicResponse {
    #[serde(rename = "subsonic-response")]
    inner: ResponseInner,
}

#[derive(Deserialize)]
struct ResponseInner {
    status: String,
    error: Option<SubsonicError>,
    artists: Option<ArtistsWrapper>,
    artist: Option<ArtistDetail>,
    album: Option<AlbumDetail>,
    #[serde(rename = "searchResult3")]
    search_result3: Option<SearchResult3>,
}

#[derive(Deserialize)]
struct SubsonicError {
    message: String,
}

#[derive(Deserialize)]
struct ArtistsWrapper {
    index: Vec<ArtistIndex>,
}

#[derive(Deserialize)]
struct ArtistIndex {
    artist: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct ArtistDetail {
    album: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct AlbumDetail {
    song: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct SearchResult3 {
    song: Option<serde_json::Value>,
    artist: Option<serde_json::Value>,
    album: Option<serde_json::Value>,
}

#[derive(Deserialize, Clone)]
struct RawArtist {
    id: String,
    name: String,
    #[serde(rename = "albumCount", default)]
    album_count: u32,
}

#[derive(Deserialize, Clone)]
struct RawAlbum {
    id: String,
    name: String,
    artist: String,
    #[serde(rename = "artistId")]
    artist_id: String,
    year: Option<u32>,
    #[serde(rename = "coverArt")]
    cover_art: Option<String>,
    #[serde(rename = "songCount", default)]
    song_count: u32,
}

#[derive(Deserialize, Clone)]
struct RawSong {
    id: String,
    title: String,
    artist: String,
    album: String,
    track: Option<u32>,
    duration: Option<u32>,
    #[serde(rename = "coverArt")]
    cover_art: Option<String>,
}

// ── Client ───────────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct SubsonicClient {
    config: SubsonicConfig,
    client: reqwest::Client,
}

impl SubsonicClient {
    pub fn new(config: SubsonicConfig) -> Self {
        Self {
            config,
            client: reqwest::Client::new(),
        }
    }

    fn auth_params(&self) -> String {
        let salt: String = (0..6).map(|_| {
            let idx = rand_u8() % 36;
            if idx < 10 { (b'0' + idx) as char } else { (b'a' + idx - 10) as char }
        }).collect();
        let token = format!("{:x}", md5::compute(format!("{}{}", self.config.password, salt)));
        format!(
            "u={}&t={}&s={}&v=1.16.1&c=hagtamp&f=json",
            urlencod(&self.config.username), token, salt
        )
    }

    fn url(&self, method: &str, extra: &str) -> String {
        let base = self.config.server_url.trim_end_matches('/');
        if extra.is_empty() {
            format!("{}/rest/{}?{}", base, method, self.auth_params())
        } else {
            format!("{}/rest/{}?{}&{}", base, method, self.auth_params(), extra)
        }
    }

    async fn get(&self, method: &str, extra: &str) -> Result<ResponseInner> {
        let resp: SubsonicResponse = self.client
            .get(self.url(method, extra))
            .send().await?
            .json().await?;
        let inner = resp.inner;
        if inner.status != "ok" {
            let msg = inner.error.map(|e| e.message).unwrap_or_else(|| "unknown error".into());
            return Err(anyhow!("{}", msg));
        }
        Ok(inner)
    }

    pub async fn ping(&self) -> Result<()> {
        self.get("ping", "").await?;
        Ok(())
    }

    pub async fn get_artists(&self) -> Result<Vec<Artist>> {
        let r = self.get("getArtists", "").await?;
        let Some(artists) = r.artists else { return Ok(vec![]) };
        let mut result = vec![];
        for idx in artists.index {
            let Some(val) = idx.artist else { continue };
            let items: Vec<RawArtist> = if val.is_array() {
                serde_json::from_value(val)?
            } else {
                vec![serde_json::from_value(val)?]
            };
            for a in items {
                result.push(Artist { id: a.id, name: a.name, album_count: a.album_count });
            }
        }
        Ok(result)
    }

    pub async fn get_artist(&self, id: &str) -> Result<Vec<Album>> {
        let r = self.get("getArtist", &format!("id={}", id)).await?;
        let Some(artist) = r.artist else { return Ok(vec![]) };
        let Some(val) = artist.album else { return Ok(vec![]) };
        let items: Vec<RawAlbum> = if val.is_array() {
            serde_json::from_value(val)?
        } else {
            vec![serde_json::from_value(val)?]
        };
        Ok(items.into_iter().map(|a| Album {
            id: a.id, name: a.name, artist: a.artist, artist_id: a.artist_id,
            year: a.year, cover_art: a.cover_art, song_count: a.song_count,
        }).collect())
    }

    pub async fn get_album(&self, id: &str) -> Result<Vec<Track>> {
        let r = self.get("getAlbum", &format!("id={}", id)).await?;
        let Some(album) = r.album else { return Ok(vec![]) };
        let Some(val) = album.song else { return Ok(vec![]) };
        let items: Vec<RawSong> = if val.is_array() {
            serde_json::from_value(val)?
        } else {
            vec![serde_json::from_value(val)?]
        };
        Ok(items.into_iter().map(|s| Track {
            id: s.id, title: s.title, artist: s.artist, album: s.album,
            track: s.track, duration: s.duration, cover_art: s.cover_art,
        }).collect())
    }

    pub async fn search(&self, query: &str) -> Result<Vec<Track>> {
        let r = self.get("search3", &format!(
            "query={}&songCount=50&albumCount=0&artistCount=0", urlencod(query)
        )).await?;
        let Some(sr) = r.search_result3 else { return Ok(vec![]) };
        let Some(val) = sr.song else { return Ok(vec![]) };
        let items: Vec<RawSong> = if val.is_array() {
            serde_json::from_value(val)?
        } else {
            vec![serde_json::from_value(val)?]
        };
        Ok(items.into_iter().map(|s| Track {
            id: s.id, title: s.title, artist: s.artist, album: s.album,
            track: s.track, duration: s.duration, cover_art: s.cover_art,
        }).collect())
    }

    pub fn stream_url(&self, id: &str) -> String {
        self.url("stream", &format!("id={}&format=raw", id))
    }

    pub fn cover_art_url(&self, id: &str) -> String {
        self.url("getCoverArt", &format!("id={}&size=300", id))
    }
}

fn urlencod(s: &str) -> String {
    s.chars().flat_map(|c| match c {
        'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' => vec![c],
        _ => format!("%{:02X}", c as u32).chars().collect(),
    }).collect()
}

fn rand_u8() -> u8 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().subsec_nanos();
    (t & 0xff) as u8
}
