import { useState, useEffect } from "react";
import { load } from "@tauri-apps/plugin-store";
import { subsonic } from "../../api/subsonic";
import { useAppStore } from "../../store";
import "./Settings.css";

const STORE_FILE = "hagtamp-config.json";

export function Settings() {
  const { setConfig, setShowSettings } = useAppStore();
  const [serverUrl, setServerUrl] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    load(STORE_FILE, { autoSave: true, defaults: {} }).then(async (store) => {
      const url = await store.get<string>("serverUrl");
      const user = await store.get<string>("username");
      const pass = await store.get<string>("password");
      if (url) setServerUrl(url);
      if (user) setUsername(user);
      if (pass) setPassword(pass);
    });
  }, []);

  async function handleSave() {
    setError("");
    setLoading(true);
    const config = { serverUrl: serverUrl.trim(), username: username.trim(), password };
    try {
      subsonic.setConfig(config);
      await subsonic.ping();
      const store = await load(STORE_FILE, { autoSave: true, defaults: {} });
      await store.set("serverUrl", config.serverUrl);
      await store.set("username", config.username);
      await store.set("password", config.password);
      setConfig(config);
      setShowSettings(false);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : "Connection failed");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="settings-overlay">
      <div className="settings-panel">
        <div className="settings-title">HAGTAMP — SERVER SETTINGS</div>
        <div className="settings-field">
          <label>Server URL</label>
          <input
            value={serverUrl}
            onChange={(e) => setServerUrl(e.target.value)}
            placeholder="http://localhost:4533"
            spellCheck={false}
          />
        </div>
        <div className="settings-field">
          <label>Username</label>
          <input
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            spellCheck={false}
          />
        </div>
        <div className="settings-field">
          <label>Password</label>
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        {error && <div className="settings-error">{error}</div>}
        <div className="settings-actions">
          <button onClick={handleSave} disabled={loading}>
            {loading ? "CONNECTING..." : "CONNECT"}
          </button>
        </div>
      </div>
    </div>
  );
}

export async function tryLoadConfig(): Promise<void> {
  try {
    const store = await load(STORE_FILE, { autoSave: true, defaults: {} });
    const url = await store.get<string>("serverUrl");
    const user = await store.get<string>("username");
    const pass = await store.get<string>("password");
    if (url && user && pass) {
      const config = { serverUrl: url, username: user, password: pass };
      subsonic.setConfig(config);
      await subsonic.ping();
      useAppStore.getState().setConfig(config);
    } else {
      useAppStore.getState().setShowSettings(true);
    }
  } catch {
    useAppStore.getState().setShowSettings(true);
  }
}
