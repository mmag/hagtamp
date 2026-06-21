export interface SubsonicConfig {
  serverUrl: string;
  username: string;
  password: string;
}

export interface Artist {
  id: string;
  name: string;
  albumCount?: number;
  coverArt?: string;
}

export interface Album {
  id: string;
  name: string;
  artist: string;
  artistId: string;
  year?: number;
  coverArt?: string;
  songCount?: number;
  duration?: number;
}

export interface Track {
  id: string;
  title: string;
  album: string;
  albumId: string;
  artist: string;
  artistId: string;
  track?: number;
  year?: number;
  duration?: number;
  bitRate?: number;
  coverArt?: string;
  contentType?: string;
  suffix?: string;
}

export interface SearchResults {
  artists: Artist[];
  albums: Album[];
  tracks: Track[];
}
