import { create } from "zustand";
import { SubsonicConfig } from "../types/subsonic";

interface AppStore {
  config: SubsonicConfig | null;
  isConfigured: boolean;
  showSettings: boolean;
  setConfig: (config: SubsonicConfig) => void;
  setShowSettings: (show: boolean) => void;
}

export const useAppStore = create<AppStore>((set) => ({
  config: null,
  isConfigured: false,
  showSettings: false,
  setConfig: (config) => set({ config, isConfigured: true }),
  setShowSettings: (show) => set({ showSettings: show }),
}));
