import { useEffect, useRef, useCallback } from "react";
import Webamp from "webamp";
import { Track } from "../types/subsonic";
import { subsonic } from "../api/subsonic";

interface WebampTrack {
  metaData: { title: string; artist: string; album?: string; duration?: number };
  url: string;
}

function toWebampTrack(t: Track): WebampTrack {
  return {
    metaData: {
      title: t.title,
      artist: t.artist,
      album: t.album,
      duration: t.duration,
    },
    url: subsonic.getStreamUrl(t.id),
  };
}

interface Props {
  tracksToPlay?: { tracks: Track[]; startIndex: number } | null;
  tracksToEnqueue?: Track[] | null;
  onReady?: () => void;
}

export function WebampPlayer({ tracksToPlay, tracksToEnqueue, onReady }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const webampRef = useRef<InstanceType<typeof Webamp> | null>(null);

  useEffect(() => {
    if (!containerRef.current) return;

    const wa = new Webamp({
      initialTracks: [
        {
          metaData: { title: "hagtamp", artist: "Select a track from the library" },
          url: "",
        },
      ],
    });

    wa.renderWhenReady(containerRef.current).then(() => {
      onReady?.();
    });

    webampRef.current = wa;

    return () => {
      wa.dispose();
      webampRef.current = null;
    };
  }, []);

  const play = useCallback(async (tracks: Track[], startIndex = 0) => {
    const wa = webampRef.current;
    if (!wa) return;
    const waTracks = tracks.map(toWebampTrack);
    await wa.setTracksToPlay(waTracks);
    // Webamp starts playing from track 0 automatically; seek to startIndex if needed
    if (startIndex > 0) {
      // skip forward by calling next() startIndex times
      for (let i = 0; i < startIndex; i++) {
        (wa as unknown as { store: { dispatch: (a: { type: string }) => void } }).store?.dispatch({ type: "NEXT_TRACK" });
      }
    }
  }, []);

  const enqueue = useCallback(async (tracks: Track[]) => {
    const wa = webampRef.current;
    if (!wa) return;
    await wa.appendTracks(tracks.map(toWebampTrack));
  }, []);

  useEffect(() => {
    if (tracksToPlay) play(tracksToPlay.tracks, tracksToPlay.startIndex);
  }, [tracksToPlay, play]);

  useEffect(() => {
    if (tracksToEnqueue) enqueue(tracksToEnqueue);
  }, [tracksToEnqueue, enqueue]);

  return <div ref={containerRef} style={{ position: "relative", zIndex: 1 }} />;
}
