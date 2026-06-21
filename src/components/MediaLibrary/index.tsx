import { useState, useRef } from "react";
import { ArtistList } from "./ArtistList";
import { AlbumList } from "./AlbumList";
import { TrackList } from "./TrackList";
import { Artist, Album, Track } from "../../types/subsonic";
import { subsonic } from "../../api/subsonic";
import "./MediaLibrary.css";

type View = "artists" | "albums" | "tracks" | "search";

interface Props {
  onPlayTracks: (tracks: Track[], startIndex?: number) => void;
  onEnqueueTracks: (tracks: Track[]) => void;
}

export function MediaLibrary({ onPlayTracks, onEnqueueTracks }: Props) {
  const [view, setView] = useState<View>("artists");
  const [selectedArtist, setSelectedArtist] = useState<Artist | null>(null);
  const [selectedAlbum, setSelectedAlbum] = useState<Album | null>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [searchResults, setSearchResults] = useState<Track[]>([]);
  const searchRef = useRef<HTMLInputElement>(null);

  function handleArtistSelect(artist: Artist) {
    setSelectedArtist(artist);
    setSelectedAlbum(null);
    setView("albums");
  }

  function handleAlbumSelect(album: Album) {
    setSelectedAlbum(album);
    setView("tracks");
  }

  function handleBack() {
    if (view === "tracks") {
      setView("albums");
      setSelectedAlbum(null);
    } else if (view === "albums") {
      setView("artists");
      setSelectedArtist(null);
    }
  }

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await subsonic.search3(searchQuery);
    setSearchResults(results.tracks);
    setView("search");
  }

  const breadcrumb = [
    view !== "artists" && view !== "search" && selectedArtist ? selectedArtist.name : null,
    view === "tracks" && selectedAlbum ? selectedAlbum.name : null,
  ].filter(Boolean).join(" / ");

  return (
    <div className="media-library">
      <div className="ml-header">
        <div className="ml-title">MEDIA LIBRARY</div>
        <div className="ml-search">
          <input
            ref={searchRef}
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && handleSearch()}
            placeholder="SEARCH..."
          />
          <button onClick={handleSearch}>GO</button>
        </div>
      </div>

      <div className="ml-nav">
        <button
          className={view === "artists" ? "active" : ""}
          onClick={() => { setView("artists"); setSelectedArtist(null); setSelectedAlbum(null); }}
        >
          ARTISTS
        </button>
        {(view === "albums" || view === "tracks") && (
          <button onClick={handleBack}>← BACK</button>
        )}
        {breadcrumb && <span className="ml-breadcrumb">{breadcrumb}</span>}
      </div>

      <div className="ml-content">
        {view === "artists" && (
          <ArtistList onSelect={handleArtistSelect} />
        )}
        {view === "albums" && selectedArtist && (
          <AlbumList
            artistId={selectedArtist.id}
            onSelect={handleAlbumSelect}
            onPlayAll={(tracks) => onPlayTracks(tracks)}
          />
        )}
        {view === "tracks" && selectedAlbum && (
          <TrackList
            albumId={selectedAlbum.id}
            onPlay={(tracks, i) => onPlayTracks(tracks, i)}
            onEnqueue={(tracks) => onEnqueueTracks(tracks)}
          />
        )}
        {view === "search" && (
          <TrackList
            tracks={searchResults}
            onPlay={(tracks, i) => onPlayTracks(tracks, i)}
            onEnqueue={(tracks) => onEnqueueTracks(tracks)}
          />
        )}
      </div>
    </div>
  );
}
