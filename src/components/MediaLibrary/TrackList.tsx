import { useEffect, useState } from "react";
import { Track } from "../../types/subsonic";
import { subsonic } from "../../api/subsonic";

function formatDuration(seconds?: number): string {
  if (!seconds) return "";
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

interface Props {
  albumId?: string;
  tracks?: Track[];
  onPlay: (tracks: Track[], startIndex: number) => void;
  onEnqueue: (tracks: Track[]) => void;
}

export function TrackList({ albumId, tracks: propTracks, onPlay, onEnqueue }: Props) {
  const [tracks, setTracks] = useState<Track[]>(propTracks ?? []);
  const [loading, setLoading] = useState(!propTracks);
  const [error, setError] = useState("");

  useEffect(() => {
    if (propTracks) {
      setTracks(propTracks);
      return;
    }
    if (!albumId) return;
    setLoading(true);
    subsonic.getAlbum(albumId)
      .then(setTracks)
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "Error"))
      .finally(() => setLoading(false));
  }, [albumId, propTracks]);

  if (loading) return <div className="ml-status">LOADING...</div>;
  if (error) return <div className="ml-status ml-error">{error}</div>;

  return (
    <div>
      {tracks.length > 0 && (
        <div className="ml-track-actions">
          <button onClick={() => onPlay(tracks, 0)}>▶ PLAY ALL</button>
          <button onClick={() => onEnqueue(tracks)}>+ ENQUEUE ALL</button>
        </div>
      )}
      <ul className="ml-list">
        {tracks.map((t, i) => (
          <li
            key={t.id}
            onDoubleClick={() => onPlay(tracks, i)}
            title={`${t.artist} — ${t.title}`}
          >
            <span className="ml-track-num">{t.track ?? i + 1}.</span>
            <span className="ml-item-name">{t.title}</span>
            <span className="ml-item-meta">{formatDuration(t.duration)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
