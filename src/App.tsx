import { useEffect, useState } from "react";
import { WebampPlayer } from "./components/WebampPlayer";
import { MediaLibrary } from "./components/MediaLibrary";
import { Settings, tryLoadConfig } from "./components/Settings";
import { useAppStore } from "./store";
import { Track } from "./types/subsonic";
import "./App.css";

export function App() {
  const { isConfigured, showSettings } = useAppStore();
  const [tracksToPlay, setTracksToPlay] = useState<{ tracks: Track[]; startIndex: number } | null>(null);
  const [tracksToEnqueue, setTracksToEnqueue] = useState<Track[] | null>(null);

  useEffect(() => {
    tryLoadConfig();
  }, []);

  function handlePlay(tracks: Track[], startIndex = 0) {
    setTracksToPlay({ tracks, startIndex });
    setTracksToEnqueue(null);
  }

  function handleEnqueue(tracks: Track[]) {
    setTracksToEnqueue(tracks);
    setTracksToPlay(null);
  }

  return (
    <div className="app">
      {showSettings && <Settings />}

      <div className="app-player">
        <WebampPlayer
          tracksToPlay={tracksToPlay}
          tracksToEnqueue={tracksToEnqueue}
        />
      </div>

      {isConfigured && (
        <div className="app-library">
          <MediaLibrary
            onPlayTracks={handlePlay}
            onEnqueueTracks={handleEnqueue}
          />
        </div>
      )}
    </div>
  );
}

export default App;
