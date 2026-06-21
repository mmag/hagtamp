import { useEffect, useState } from "react";
import { Album, Track } from "../../types/subsonic";
import { subsonic } from "../../api/subsonic";

interface Props {
  artistId: string;
  onSelect: (album: Album) => void;
  onPlayAll: (tracks: Track[]) => void;
}

export function AlbumList({ artistId, onSelect, onPlayAll }: Props) {
  const [albums, setAlbums] = useState<Album[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    setLoading(true);
    subsonic.getArtist(artistId)
      .then(setAlbums)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "Error"))
      .finally(() => setLoading(false));
  }, [artistId]);

  async function handlePlayAll(album: Album) {
    const tracks = await subsonic.getAlbum(album.id);
    onPlayAll(tracks);
  }

  if (loading) return <div className="ml-status">LOADING...</div>;
  if (error) return <div className="ml-status ml-error">{error}</div>;

  return (
    <ul className="ml-list">
      {albums.map((a) => (
        <li key={a.id} onClick={() => onSelect(a)} onDoubleClick={() => handlePlayAll(a)}>
          <span className="ml-item-name">
            {a.year ? `[${a.year}] ` : ""}{a.name}
          </span>
          {a.songCount !== undefined && (
            <span className="ml-item-meta">{a.songCount} tracks</span>
          )}
        </li>
      ))}
    </ul>
  );
}
