import { invoke, convertFileSrc } from "@tauri-apps/api/core";
export type Rect = { x: number; y: number; width: number; height: number };
export type MediaItem = {
  id: string;
  name: string;
  kind: "image" | "video";
  path: string;
  createdAt: string;
  width?: number;
  height?: number;
  duration?: number;
  recordingOptions?:Record<string,unknown>;
};
export type AppState = {
  library: MediaItem[];
  selection: Rect | null;
  recording: { active: boolean; paused: boolean; elapsed: number } | null;
  settings: Record<string, unknown>;
  error?: string;
  previewPath?: string;
  editingId?: string;
  activeItemId?: string;
  selectionDisplay?: {
    id: string;
    width: number;
    height: number;
    scaleFactor: number;
    backgroundPath: string;
  } | null;
  selectionMode?: string;
  scrolling?: {
    active: boolean;
    previewPath?: string;
    acceptedFrames: number;
    status: string;
  } | null;
  shortcutErrors?: string[];
  capabilities?: {
    recording: boolean;
    systemAudio: boolean;
    microphone: boolean;
    camera: boolean;
    clicks?: boolean;
    keystrokes?: boolean;
  };
};
export const emptyState: AppState = {
  library: [],
  selection: null,
  recording: null,
  settings: {},
};
export const api = <T = void>(
  command: string,
  args: Record<string, unknown> = {},
) => invoke<T>(command, args);
export const mediaUrl = (path: string) =>
  path.startsWith("data:") ? path : convertFileSrc(path);
export type Cut = { start: number; end: number };
export { normalizeRect, normalizeCuts, clampRect } from "./geometry";
