import { fetch } from "@tauri-apps/plugin-http";
import { Artist, Album, Track, SubsonicConfig, SearchResults } from "../types/subsonic";

const APP_NAME = "hagtamp";
const API_VERSION = "1.16.1";

function md5(input: string): string {
  // Simple MD5 using SubtleCrypto is async; we use a synchronous implementation
  // via the built-in approach for Subsonic token auth
  let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476;
  const msg = new TextEncoder().encode(input);
  const padded = new Uint8Array(Math.ceil((msg.length + 9) / 64) * 64);
  padded.set(msg);
  padded[msg.length] = 0x80;
  const bits = BigInt(msg.length * 8);
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Number(bits & 0xffffffffn), true);
  view.setUint32(padded.length - 4, Number(bits >> 32n), true);

  const S = [7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20,4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21];
  const K = Array.from({length: 64}, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 2 ** 32) >>> 0);

  for (let i = 0; i < padded.length; i += 64) {
    const M = Array.from({length: 16}, (_, j) => view.getUint32(i + j * 4, true));
    let [a, b, c, d] = [h0, h1, h2, h3];
    for (let j = 0; j < 64; j++) {
      let F: number, g: number;
      if (j < 16)      { F = (b & c) | (~b & d); g = j; }
      else if (j < 32) { F = (d & b) | (~d & c); g = (5 * j + 1) % 16; }
      else if (j < 48) { F = b ^ c ^ d;           g = (3 * j + 5) % 16; }
      else             { F = c ^ (b | ~d);         g = (7 * j) % 16; }
      F = (F + a + K[j] + M[g]) >>> 0;
      a = d; d = c; c = b;
      b = (b + ((F << S[j]) | (F >>> (32 - S[j])))) >>> 0;
    }
    h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0; h3 = (h3 + d) >>> 0;
  }

  return [h0, h1, h2, h3]
    .map(n => n.toString(16).padStart(8, "0").match(/../g)!.reverse().join(""))
    .join("");
}

function randomSalt(len = 6): string {
  const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
  return Array.from({length: len}, () => chars[Math.floor(Math.random() * chars.length)]).join("");
}

class SubsonicClient {
  private config: SubsonicConfig | null = null;

  setConfig(config: SubsonicConfig) {
    this.config = config;
  }

  private authParams(): string {
    if (!this.config) throw new Error("Subsonic not configured");
    const salt = randomSalt();
    const token = md5(this.config.password + salt);
    return `u=${encodeURIComponent(this.config.username)}&t=${token}&s=${salt}&v=${API_VERSION}&c=${APP_NAME}&f=json`;
  }

  private url(method: string, extra = ""): string {
    if (!this.config) throw new Error("Subsonic not configured");
    const base = this.config.serverUrl.replace(/\/$/, "");
    return `${base}/rest/${method}?${this.authParams()}${extra ? "&" + extra : ""}`;
  }

  private async get<T>(method: string, extra = ""): Promise<T> {
    const res = await fetch(this.url(method, extra));
    const json = await res.json() as { "subsonic-response": { status: string; error?: { code: number; message: string }; [key: string]: unknown } };
    const root = json["subsonic-response"];
    if (root.status !== "ok") throw new Error(root.error?.message ?? "Subsonic error");
    return root as T;
  }

  async ping(): Promise<void> {
    await this.get("ping");
  }

  async getArtists(): Promise<Artist[]> {
    const data = await this.get<{ artists: { index: { artist: Artist | Artist[] }[] } }>("getArtists");
    return data.artists.index.flatMap(idx =>
      Array.isArray(idx.artist) ? idx.artist : [idx.artist]
    );
  }

  async getArtist(id: string): Promise<Album[]> {
    const data = await this.get<{ artist: { album: Album | Album[] } }>("getArtist", `id=${id}`);
    const albums = data.artist.album;
    return Array.isArray(albums) ? albums : [albums];
  }

  async getAlbum(id: string): Promise<Track[]> {
    const data = await this.get<{ album: { song: Track | Track[] } }>("getAlbum", `id=${id}`);
    const songs = data.album.song;
    return Array.isArray(songs) ? songs : [songs];
  }

  async search3(query: string): Promise<SearchResults> {
    const data = await this.get<{
      searchResult3: {
        artist?: Artist | Artist[];
        album?: Album | Album[];
        song?: Track | Track[];
      }
    }>("search3", `query=${encodeURIComponent(query)}&artistCount=20&albumCount=20&songCount=50`);
    const r = data.searchResult3;
    return {
      artists: r.artist ? (Array.isArray(r.artist) ? r.artist : [r.artist]) : [],
      albums: r.album ? (Array.isArray(r.album) ? r.album : [r.album]) : [],
      tracks: r.song ? (Array.isArray(r.song) ? r.song : [r.song]) : [],
    };
  }

  getStreamUrl(id: string): string {
    return this.url("stream", `id=${id}&format=mp3`);
  }

  getCoverArtUrl(id: string, size = 300): string {
    return this.url("getCoverArt", `id=${id}&size=${size}`);
  }
}

export const subsonic = new SubsonicClient();
