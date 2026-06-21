import { useEffect, useState } from "react";
import { Artist } from "../../types/subsonic";
import { subsonic } from "../../api/subsonic";

interface Props {
  onSelect: (artist: Artist) => void;
}

export function ArtistList({ onSelect }: Props) {
  const [artists, setArtists] = useState<Artist[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    subsonic.getArtists()
      .then(setArtists)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "Error"))
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <div className="ml-status">LOADING...</div>;
  if (error) return <div className="ml-status ml-error">{error}</div>;

  return (
    <ul className="ml-list">
      {artists.map((a) => (
        <li key={a.id} onDoubleClick={() => onSelect(a)} onClick={() => onSelect(a)}>
          <span className="ml-item-name">{a.name}</span>
          {a.albumCount !== undefined && (
            <span className="ml-item-meta">{a.albumCount} albums</span>
          )}
        </li>
      ))}
    </ul>
  );
}
