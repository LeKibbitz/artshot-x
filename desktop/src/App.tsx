import { useEffect, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import { Camera as PhotoIcon, ScanLine, Video, X, Trash2, Pencil, Save, Copy, Monitor, SquareDashed } from "lucide-react";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  api,
  emptyState,
  mediaUrl,
  normalizeRect,
  normalizeCuts,
  clampRect,
} from "./api";
import type { AppState, MediaItem, Rect, Cut } from "./api";
import "./App.css";
const label = getCurrentWindow().label;
function Button({
  children,
  onClick,
  disabled = false,
  title = "",
}: {
  children: React.ReactNode;
  onClick: () => void;
  disabled?: boolean;
  title?: string;
}) {
  return (
    <button disabled={disabled} onClick={onClick} title={title}>
      {children}
    </button>
  );
}
export default function App() {
  const [state, setState] = useState<AppState>(emptyState);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [editing, setEditing] = useState<MediaItem | null>(null);
  const [filter, setFilter] = useState("all");
  async function run(command: string, args: Record<string, unknown> = {}) {
    setBusy(true);
    try {
      await api(command, args);
    } catch (e) {
      setError(String(e));
    } finally {
      setBusy(false);
    }
  }
  useEffect(() => {
    let cancelled = false;
    let dispose: (() => void) | undefined;
    let receivedEvent = false;
    // Subscribe before fetching: an event arriving during the fetch wins.
    listen<AppState>("app-state", (e) => {
      if (cancelled) return;
      receivedEvent = true;
      setState(e.payload);
      setLoaded(true);
    }).then(async (fn) => {
      if (cancelled) { fn(); return; }
      dispose = fn;
      const snapshot = await api<AppState>("get_state");
      if (!cancelled && !receivedEvent) {
        setState(snapshot);
        setLoaded(true);
      }
    }).catch((e) => { if (!cancelled) setError(String(e)); });
    return () => { cancelled = true; dispose?.(); };
  }, []);
  useEffect(() => {
    if (state.editingId || state.activeItemId)
      setEditing(
        state.library.find(
          (i) => i.id === (state.editingId ?? state.activeItemId),
        ) ?? null,
      );
  }, [state.editingId, state.activeItemId, state.library]);
  useEffect(() => { setError(""); }, [state.selectionDisplay?.backgroundPath]);
  const latest =
    state.library.find((i) => i.id === state.activeItemId) ?? state.library[0];
  const banner = (error || state.error) && (
    <div className="error" role="alert">
      {error || state.error}
      <button onClick={()=>{setError("");api("dismiss_error").catch(()=>{});}}>×</button><button onClick={()=>run("open_permissions")}>Autorisations</button>
    </div>
  );
  if (label === "selection")
    return (
      <>
        {banner}
        <Selection initial={state.selection} state={state} run={run} />
      </>
    );
  if (label === "recording")
    return (
      <div className="floating">
        {banner}
        <span className="red-dot" />
        <strong
          data-tauri-drag-region
          onPointerDown={() =>
            getCurrentWindow()
              .startDragging()
              .catch((e) => setError(String(e)))
          }
        >
          {formatTime(state.recording?.elapsed ?? 0)}
        </strong>
        <Button
          onClick={() =>
            run("recording_action", {
              action: state.recording?.paused ? "resume" : "pause",
            })
          }
        >
          {state.recording?.paused ? "▶ Reprendre" : "Ⅱ Pause"}
        </Button>
        <Button onClick={() => run("recording_action", { action: "stop" })}>
          ■ Terminer
        </Button>
        <Button onClick={() => run("recording_action", { action: "restart" })}>
          ↻
        </Button>
        <Button onClick={() => run("recording_action", { action: "delete" })}>
          ⌫
        </Button>
      </div>
    );
  if (label === "camera") return <Camera settings={state.settings} recording={state.recording?.active??false} />;
  if (label === "scrolling")
    return (
      <div className="scroll-window">
        {banner}
        <header>
          <span className="red-dot" /> Capture défilante
          <Button onClick={() => run("finish_scroll")}>Terminer</Button>
          <Button title="Annuler la capture défilante" onClick={() => run("close_overlay")}>Annuler</Button>
        </header>
        <p>Faites défiler lentement la fenêtre capturée.</p>
        <p role="status">{state.scrolling?.acceptedFrames ?? 0} images assemblées · {state.scrolling?.status || "En attente"}</p>
        {(state.scrolling?.previewPath ?? state.previewPath) ? (
          <img
            src={mediaUrl((state.scrolling?.previewPath ?? state.previewPath)!)}
            alt="Aperçu intégral de la capture"
          />
        ) : (
          <div className="empty">En attente de la première image…</div>
        )}
      </div>
    );
  if (label === "quick")
    return (
      <div className={`quick${banner ? " quick-error" : ""}`}>
        {banner}
        {latest && !banner && (
          <>
            {latest.kind === "video" ? <video src={mediaUrl(latest.path)} muted preload="metadata" /> : <img src={mediaUrl(latest.path)} alt={latest.name} />}
            <div className="toolbar">
              <Button onClick={() => run("delete_item", { id: latest.id })}>
                <Trash2 aria-hidden="true" />Supprimer
              </Button>
              <Button onClick={() => run("open_editor", { id: latest.id })}>
                <Pencil aria-hidden="true" />Modifier
              </Button>
              <Button onClick={() => run("save_item", { id: latest.id })}>
                <Save aria-hidden="true" />Enregistrer
              </Button>
              <Button disabled={latest.kind !== "image"} onClick={() => run("copy_image", { id: latest.id })}>
                <Copy aria-hidden="true" />Copier
              </Button>
            </div>
          </>
        )}
      </div>
    );
  if (!loaded)
    return (
      <div className="app">
        <main>
          {banner}
          <div className="empty">
            <h2>Ouverture de la bibliothèque…</h2>
            <p>Connexion aux fonctions de capture.</p>
          </div>
        </main>
      </div>
    );
  return (
    <div className="app">
      {banner}
      <aside>
        <div className="brand">
          <span>◩</span> ArtShot <b>X</b>
        </div>
        <div className="aside-label">ESPACE DE TRAVAIL</div>
        <button
          className={filter === "all" ? "nav active" : "nav"}
          onClick={() => setFilter("all")}
        >
          ▦ Toutes les captures <small>{state.library.length}</small>
        </button>
        <button
          className={filter === "image" ? "nav active" : "nav"}
          onClick={() => setFilter("image")}
        >
          ▧ Images
        </button>
        <button
          className={filter === "video" ? "nav active" : "nav"}
          onClick={() => setFilter("video")}
        >
          ▷ Vidéos
        </button>
        <div className="aside-bottom">{Boolean(state.shortcutErrors?.length)&&<p>Raccourcis occupés. Fermez l’ancienne version d’ArtShot X.</p>}<button onClick={()=>run("open_permissions")}>Autorisations</button>
          <span className="status-dot" /> Votre bibliothèque locale
        </div>
      </aside>
      <main>
        {editing ? (
          <>
            <header>
              <Button onClick={() => setEditing(null)}>← Bibliothèque</Button>
              <h2>{editing.name}</h2>
            </header>
            {editing.kind === "image" ? (
              <ImageEditor item={editing} run={run} />
            ) : (
              <VideoEditor item={editing} run={run} />
            )}
          </>
        ) : (
          <>
            <header>
              <div>
                <div className="eyebrow">CAPTURER · ANNOTER · PARTAGER</div>
                <h1>Votre regard, en images.</h1>
                <p>Les captures utiles, toujours à portée de main.</p>
              </div>
              <div className="toolbar">
                <Button
                  disabled={busy}
                  onClick={() => run("capture_fullscreen")}
                >
                  Écran entier
                </Button>
                <Button disabled={busy} onClick={() => run("begin_selection")}>
                  ＋ Nouvelle capture
                </Button>
              </div>
            </header>
            <div className="library-heading">
              <h2>
                {filter === "video"
                  ? "Vidéos"
                  : filter === "image"
                    ? "Images"
                    : "Bibliothèque"}
              </h2>
              <span>
                {
                  state.library.filter(
                    (i) => filter === "all" || i.kind === filter,
                  ).length
                }{" "}
                éléments
              </span>
            </div>
            {state.library.length === 0 ? (
              <div className="empty">
                <div className="empty-icon">⌘</div>
                <h2>Une idée mérite une capture.</h2>
                <p>
                  Sélectionnez une zone de l’écran, puis choisissez photo,
                  défilement ou vidéo.
                </p>
                <Button onClick={() => run("begin_selection")}>
                  Créer ma première capture
                </Button>
              </div>
            ) : (
              <div className="grid">
                {state.library
                  .filter((i) => filter === "all" || i.kind === filter)
                  .map((item) => (
                    <article key={item.id}>
                      <button
                        className="thumbnail"
                        onClick={() => setEditing(item)}
                      >
                        {item.kind === "image" ? (
                          <img src={mediaUrl(item.path)} alt={item.name} />
                        ) : (
                          <video src={mediaUrl(item.path)} preload="metadata" />
                        )}
                        <span className="media-badge">
                          {item.kind === "image" ? "IMAGE" : "VIDÉO"}
                        </span>
                      </button>
                      <div className="card-body">
                        <strong>{item.name}</strong>
                        <small>
                          {new Date(item.createdAt).toLocaleDateString("fr-FR")}{" "}
                          {item.width && ` · ${item.width} × ${item.height}`}
                        </small>
                        <div className="card-actions">
                          <Button onClick={() => setEditing(item)}>
                            Modifier
                          </Button>
                          <Button
                            onClick={() => run("save_item", { id: item.id })}
                          >
                            ↗ Exporter
                          </Button>
                          <Button
                            title="Supprimer"
                            onClick={() => run("delete_item", { id: item.id })}
                          >
                            ⌫
                          </Button>
                        </div>
                      </div>
                    </article>
                  ))}
              </div>
            )}
          </>
        )}
      </main>
    </div>
  );
}
const formatTime = (seconds: number) =>
  `${Math.floor(seconds / 60)
    .toString()
    .padStart(2, "0")}:${Math.floor(seconds % 60)
    .toString()
    .padStart(2, "0")}`;
function Selection({
  initial,
  state,
  run,
}: {
  initial: Rect | null;
  state: AppState;
  run: (c: string, a?: Record<string, unknown>) => Promise<void>;
}) {
  const scale = state.selectionDisplay?.scaleFactor ?? 1;
  const cssRect = (r: Rect): Rect => ({
    x: r.x / scale,
    y: r.y / scale,
    width: r.width / scale,
    height: r.height / scale,
  });
  const [rect, setRect] = useState<Rect | null>(
    initial ? cssRect(initial) : null,
  );
  const [options, setOptions] = useState(false);
  const rectRef = useRef(rect);
  rectRef.current = rect;
  const [capturing, setCapturing] = useState(false);
  const capturePending = useRef(false);
  const [captureError, setCaptureError] = useState("");
  async function capture(command: string, args: Record<string, unknown> = {}) {
    const current = rectRef.current;
    if (!current || current.width < 2 || current.height < 2 || capturePending.current) return;
    capturePending.current = true;
    setCapturing(true);
    setCaptureError("");
    try {
      await api("set_selection", { rect: { x: current.x * scale, y: current.y * scale, width: current.width * scale, height: current.height * scale } });
      await run(command, args);
    } catch (error) {
      setCaptureError(String(error));
    } finally { capturePending.current = false; setCapturing(false); }
  }
  const [mic, setMic] = useState(true),
    [system, setSystem] = useState(true),
    [camera, setCamera] = useState(false),
    [shape, setShape] = useState("circle"),
    [size, setSize] = useState(24),
    [zoom, setZoom] = useState(1),
    [cursor, setCursor] = useState(true),
    [clicks, setClicks] = useState(false),
    [keys, setKeys] = useState(false);
  const settingsLoaded = useRef(false);
  const gesture = useRef<{
    start: { x: number; y: number };
    rect: Rect | null;
    handle: string;
  } | null>(null);
  useEffect(() => {
    if (!settingsLoaded.current && Object.keys(state.settings).length) {
      const s = state.settings;
      setMic(s.microphone !== false);
      setSystem(s.systemAudio !== false);
      setCamera(s.camera === true);
      setShape(String(s.cameraShape ?? "circle"));
      setSize(Number(s.cameraSize ?? 24));
      setZoom(Number(s.cameraZoom ?? 1));
      setCursor(s.cursor !== false);
      setClicks(s.clicks === true);
      setKeys(s.keystrokes === true);
      settingsLoaded.current = true;
    }
  }, [state.settings]);
  useEffect(() => {
    setRect(initial ? cssRect(initial) : null);
    setOptions(false);
    setCaptureError("");
    gesture.current = null;
  }, [state.selectionDisplay?.backgroundPath, state.selectionDisplay?.id, scale]);
  useEffect(() => {
    const f = (e: KeyboardEvent) => {
      if (e.key === "Escape") run("close_overlay");
      if (e.key === "Enter" && rect && rect.width > 1 && rect.height > 1)
        capture("capture_photo");
    };
    window.addEventListener("keydown", f);
    return () => window.removeEventListener("keydown", f);
  }, [run, rect]);
  useEffect(() => {
    if (!settingsLoaded.current) return;
    const timer = window.setTimeout(() => {
      run("update_settings", {
        settings: {
          microphone: mic,
          systemAudio: system,
          camera,
          cameraShape: shape,
          cameraSize: size,
          cameraZoom: zoom,
          cameraX: 0.78,
          cameraY: 0.68,
          cursor,
          clicks,
          keystrokes: keys,
        },
      });
    }, 250);
    return () => window.clearTimeout(timer);
  }, [mic, system, camera, shape, size, zoom, cursor, clicks, keys]);
  function down(e: ReactPointerEvent, handle = "new") {
    if ((e.target as HTMLElement).closest(".selection-toolbar")) return;
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    gesture.current = { start: { x: e.clientX, y: e.clientY }, rect, handle };
    if (handle === "new") { rectRef.current = null; setRect(null); setOptions(false); }
  }
  function move(e: ReactPointerEvent) {
    const g = gesture.current;
    if (!g) return;
    const dx = e.clientX - g.start.x,
      dy = e.clientY - g.start.y;
    if (g.handle === "new")
      setRect(
        normalizeRect(g.start, {
          x: Math.max(0, Math.min(e.clientX, window.innerWidth)),
          y: Math.max(0, Math.min(e.clientY, window.innerHeight)),
        }),
      );
    else if (g.rect) {
      const r = g.rect;
      if (g.handle === "move")
        setRect(
          clampRect(
            { ...r, x: r.x + dx, y: r.y + dy },
            window.innerWidth,
            window.innerHeight,
          ),
        );
      else {
        let x = r.x,
          y = r.y,
          right = x + r.width,
          bottom = y + r.height;
        if (g.handle.includes("w")) x += dx;
        if (g.handle.includes("e")) right += dx;
        if (g.handle.includes("n")) y += dy;
        if (g.handle.includes("s")) bottom += dy;
        setRect(
          clampRect(
            normalizeRect({ x, y }, { x: right, y: bottom }),
            window.innerWidth,
            window.innerHeight,
          ),
        );
      }
    }
  }
  function up() {
    if (!gesture.current) return;
    gesture.current = null;
    if (rect && rect.width >= 2 && rect.height >= 2)
      run("set_selection", {
        rect: {
          x: rect.x * scale,
          y: rect.y * scale,
          width: rect.width * scale,
          height: rect.height * scale,
        },
      });
  }
  return (
    <div
      className="selection-overlay"
      style={
        state.selectionDisplay?.backgroundPath
          ? {
              backgroundImage: `url("${mediaUrl(state.selectionDisplay.backgroundPath)}")`,
              backgroundSize: "100% 100%",
            }
          : undefined
      }
      onPointerDown={(e) => down(e)}
      onPointerMove={move}
      onPointerUp={up}
      onPointerCancel={() => { gesture.current = null; }}
    >
      {captureError && <div className="error" role="alert">{captureError}</div>}
      {!rect && (
        <div className="selection-hint">
          Glissez pour sélectionner une zone · Échap pour fermer
        </div>
      )}
      {rect && (
        <div
          className="selection-rect"
          style={{
            left: rect.x,
            top: rect.y,
            width: rect.width,
            height: rect.height,
          }}
          onPointerDown={(e) => {
            e.stopPropagation();
            down(e, "move");
          }}
        >
          <span className="dimensions">
            {Math.round(rect.width)} × {Math.round(rect.height)}
          </span>
          {["nw", "n", "ne", "e", "se", "s", "sw", "w"].map((h) => (
            <span
              key={h}
              className={`handle ${h}`}
              onPointerDown={(e) => {
                e.stopPropagation();
                down(e, h);
              }}
            />
          ))}
        </div>
      )}
          <div
            className="selection-toolbar"
            style={{
              position: "fixed",
              left: Math.min(
                Math.max(rect ? rect.x + rect.width / 2 : window.innerWidth / 2, Math.min(250, window.innerWidth / 2)),
                window.innerWidth - Math.min(250, window.innerWidth / 2),
              ),
              top: Math.max(
                16,
                Math.min(
                  rect ? rect.y + rect.height + 14 : window.innerHeight - 70,
                  window.innerHeight - (options ? 450 : 76),
                ),
              ),
            }}
            onPointerDown={(e) => e.stopPropagation()}
          >
            <div className="toolbar">
              <Button
                onClick={() => {
                  const full = {
                    x: 0,
                    y: 0,
                    width: window.innerWidth,
                    height: window.innerHeight,
                  };
                  setRect(full);
                  run("set_selection", {
                    rect: {
                      x: 0,
                      y: 0,
                      width: full.width * scale,
                      height: full.height * scale,
                    },
                  });
                }}
              >
                <Monitor aria-hidden="true" />Écran
              </Button>
              <Button
                onClick={() => {
                  setRect(null);
                  run("begin_selection");
                }}
              >
                <SquareDashed aria-hidden="true" />Zone
              </Button>
              <Button disabled={capturing || !rect || rect.width < 2 || rect.height < 2} onClick={() => capture("capture_photo")}><PhotoIcon aria-hidden="true" />Photo</Button>
              <Button disabled={capturing || !rect || rect.width < 2 || rect.height < 2} onClick={() => capture("start_scroll")}><ScanLine aria-hidden="true" />Défilement</Button>
              <Button
                disabled={!rect || rect.width < 2 || rect.height < 2 || state.capabilities?.recording === false}
                onClick={() => setOptions(!options)}
              >
                <Video aria-hidden="true" />Vidéo
              </Button>
              <Button title="Fermer la sélection" onClick={() => run("close_overlay")}><X aria-hidden="true" /></Button>
            </div>
            {options && (
              <div className="record-options">
                <label>
                  <input
                    type="checkbox"
                    disabled={state.capabilities?.microphone === false}
                    checked={mic}
                    onChange={(e) => setMic(e.target.checked)}
                  />{" "}
                  Microphone
                </label>
                <label>
                  <input
                    type="checkbox"
                    disabled={state.capabilities?.systemAudio === false}
                    checked={system}
                    onChange={(e) => setSystem(e.target.checked)}
                  />{" "}
                  Audio système
                </label>
                <label>
                  <input
                    type="checkbox"
                    checked={cursor}
                    onChange={(e) => setCursor(e.target.checked)}
                  />{" "}
                  Curseur
                </label>
                <label>
                  <input
                    type="checkbox"
                    disabled={state.capabilities?.clicks === false}
                    checked={clicks}
                    onChange={(e) => setClicks(e.target.checked)}
                  />{" "}
                  Mettre en évidence les clics
                </label>
                <label>
                  <input
                    type="checkbox"
                    disabled={state.capabilities?.keystrokes === false}
                    checked={keys}
                    onChange={(e) => setKeys(e.target.checked)}
                  />{" "}
                  Afficher les touches
                </label>
                <label>
                  <input
                    type="checkbox"
                    disabled={state.capabilities?.camera === false}
                    checked={camera}
                    onChange={(e) => setCamera(e.target.checked)}
                  />{" "}
                  Caméra
                </label>
                {camera && (
                  <>
                    <select
                      aria-label="Forme de caméra"
                      value={shape}
                      onChange={(e) => setShape(e.target.value)}
                    >
                      <option value="circle">Cercle</option>
                      <option value="square">Carré</option>
                      <option value="rounded">Arrondi</option>
                      <option value="verticalOval">Ovale vertical</option>
                    </select>
                    <label>
                      Taille {size}%
                      <input
                        type="range"
                        min="12"
                        max="45"
                        value={size}
                        onChange={(e) => setSize(+e.target.value)}
                      />
                    </label>
                    <label>
                      Zoom {zoom}×
                      <input
                        type="range"
                        min="1"
                        max="3"
                        step="0.1"
                        value={zoom}
                        onChange={(e) => setZoom(+e.target.value)}
                      />
                    </label>
                  </>
                )}
                <Button
                  onClick={() =>
                    capture("start_recording", {
                      options: {
                        microphone:
                          mic && state.capabilities?.microphone !== false,
                        systemAudio:
                          system && state.capabilities?.systemAudio !== false,
                        camera: camera && state.capabilities?.camera !== false,
                        cameraShape: shape,
                        cameraSize: size,
                        cameraZoom: zoom,
                        cameraX: 0.78,
                        cameraY: 0.68,
                        cursor,
                        clicks: clicks && state.capabilities?.clicks !== false,
                        keystrokes:
                          keys && state.capabilities?.keystrokes !== false,
                      },
                    })
                  }
                >
                  Démarrer l’enregistrement
                </Button>
              </div>
            )}
          </div>
    </div>
  );
}
type Annotation = {
  tool: string;
  x: number;
  y: number;
  x2: number;
  y2: number;
  color: string;
  width: number;
  number: number;
};
function ImageEditor({
  item,
  run,
}: {
  item: MediaItem;
  run: (c: string, a?: Record<string, unknown>) => Promise<void>;
}) {
  const [tool, setTool] = useState("arrow"),
    [color, setColor] = useState("#f04b43"),
    [width, setWidth] = useState(4),
    [marks, setMarks] = useState<Annotation[]>([]);
  const canvas = useRef<HTMLCanvasElement>(null),
    base = useRef<HTMLImageElement | null>(null),
    draft = useRef<Annotation | null>(null);
  const paint = (all: Annotation[]) => {
    const c = canvas.current,
      im = base.current;
    if (!c || !im) return;
    const ctx = c.getContext("2d")!;
    ctx.clearRect(0, 0, c.width, c.height);
    ctx.drawImage(im, 0, 0);
    for (const a of all) {
      ctx.strokeStyle = a.color;
      ctx.fillStyle = a.color;
      ctx.lineWidth = a.width;
      ctx.lineCap = "round";
      if (a.tool === "rectangle")
        ctx.strokeRect(a.x, a.y, a.x2 - a.x, a.y2 - a.y);
      else if (a.tool === "step") {
        ctx.beginPath();
        ctx.arc(a.x, a.y, 18 + a.width, 0, Math.PI * 2);
        ctx.fill();
        ctx.fillStyle = "white";
        ctx.font = "bold 22px system-ui";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(String(a.number), a.x, a.y);
      } else {
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(a.x2, a.y2);
        ctx.stroke();
        const angle = Math.atan2(a.y2 - a.y, a.x2 - a.x),
          s = 16 + a.width * 2;
        ctx.beginPath();
        ctx.moveTo(a.x2, a.y2);
        ctx.lineTo(
          a.x2 - s * Math.cos(angle - 0.45),
          a.y2 - s * Math.sin(angle - 0.45),
        );
        ctx.lineTo(
          a.x2 - s * Math.cos(angle + 0.45),
          a.y2 - s * Math.sin(angle + 0.45),
        );
        ctx.closePath();
        ctx.fill();
      }
    }
  };
  useEffect(() => {
    const image = new Image();
    image.crossOrigin = "anonymous";
    image.onload = () => {
      base.current = image;
      const c = canvas.current!;
      c.width = image.naturalWidth;
      c.height = image.naturalHeight;
      paint([]);
    };
    image.src = mediaUrl(item.path);
    setMarks([]);
  }, [item.path]);
  useEffect(() => paint(marks), [marks]);
  useEffect(()=>{const undo=(e:KeyboardEvent)=>{if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==="z"){e.preventDefault();setMarks(m=>m.slice(0,-1));}};window.addEventListener("keydown",undo);return()=>window.removeEventListener("keydown",undo);},[]);
  function point(e: ReactPointerEvent) {
    const c = canvas.current!,
      r = c.getBoundingClientRect();
    return {
      x: ((e.clientX - r.left) * c.width) / r.width,
      y: ((e.clientY - r.top) * c.height) / r.height,
    };
  }
  return (
    <>
      <div className="editor-tools">
        {[
          ["arrow", "↗ Flèche"],
          ["rectangle", "□ Rectangle"],
          ["step", "① Étapes"],
        ].map(([t, name]) => (
          <button
            className={tool === t ? "active" : ""}
            key={t}
            onClick={() => setTool(t)}
          >
            {name}
          </button>
        ))}
        <input
          aria-label="Couleur"
          type="color"
          value={color}
          onChange={(e) => setColor(e.target.value)}
        />
        <label>
          Trait{" "}
          <input
            aria-label="Épaisseur"
            type="range"
            min="2"
            max="16"
            value={width}
            onChange={(e) => setWidth(+e.target.value)}
          />
        </label>
        <Button
          disabled={!marks.length}
          onClick={() => setMarks((m) => m.slice(0, -1))}
        >
          ↶ Annuler
        </Button>
        <Button
          onClick={() =>
            run("export_image", {
              id: item.id,
              dataUrl: canvas.current?.toDataURL("image/png"),
            })
          }
        >
          Exporter PNG
        </Button>
        <Button
          onClick={() =>
            run("copy_image", {
              id: item.id,
              dataUrl: canvas.current?.toDataURL("image/png"),
            })
          }
        >
          Copier
        </Button>
      </div>
      <div className="canvas-stage">
        <canvas
          ref={canvas}
          onPointerDown={(e) => {
            e.currentTarget.setPointerCapture(e.pointerId);
            const p = point(e);
            draft.current = {
              tool,
              ...p,
              x2: p.x,
              y2: p.y,
              color,
              width,
              number: marks.filter((m) => m.tool === "step").length + 1,
            };
          }}
          onPointerMove={(e) => {
            if (draft.current) {
              const p = point(e);
              draft.current = { ...draft.current, x2: p.x, y2: p.y };
              paint([...marks, draft.current]);
            }
          }}
          onPointerUp={() => {
            if (draft.current) {
              const completed = draft.current;
              setMarks((m) => [...m, completed]);
              draft.current = null;
            }
          }}
        />
      </div>
    </>
  );
}
function VideoEditor({
  item,
  run,
}: {
  item: MediaItem;
  run: (c: string, a?: Record<string, unknown>) => Promise<void>;
}) {
  const video = useRef<HTMLVideoElement>(null);
  const [duration, setDuration] = useState(item.duration ?? 0),
    [start, setStart] = useState(0),
    [end, setEnd] = useState(item.duration ?? 0),
    [cuts, setCuts] = useState<Cut[]>([]),
    [mic, setMic] = useState(100),
    [system, setSystem] = useState(100);
  const [camera,setCamera]=useState(item.recordingOptions?.camera===true),[clicks,setClicks]=useState(item.recordingOptions?.clicks===true),[keys,setKeys]=useState(item.recordingOptions?.keystrokes===true);
  const [rendered,setRendered]=useState(""),[rendering,setRendering]=useState(false),[renderError,setRenderError]=useState("");
  const payload=()=>({id:item.id,cuts:normalizeCuts(cuts,duration),microphoneGain:mic/100,systemGain:system/100,camera,clicks,keys});
  async function preview(){setRendering(true);setRenderError("");try{setRendered(await api<string>("preview_video",payload()));}catch(e){setRenderError(String(e));}finally{setRendering(false);}}
  return (
    <>
      <div className="video-stage">
        <video
          controls
          ref={video}
          src={mediaUrl(item.path)}
          onLoadedMetadata={(e) => {
            setDuration(e.currentTarget.duration);
            setEnd(e.currentTarget.duration);
          }}
        />
      </div>
      <div className="video-controls">
        <h3>Montage</h3>
        <p>Sélectionnez une plage, puis retirez-la de la vidéo.</p>
        <div className="toolbar">
          <label>
            Début{" "}
            <input
              type="number"
              min="0"
              max={duration}
              step="0.1"
              value={start}
              onChange={(e) => setStart(+e.target.value)}
            />
          </label>
          <Button onClick={() => setStart(video.current?.currentTime ?? 0)}>
            Position actuelle → début
          </Button>
          <label>
            Fin{" "}
            <input
              type="number"
              min="0"
              max={duration}
              step="0.1"
              value={end}
              onChange={(e) => setEnd(+e.target.value)}
            />
          </label>
          <Button
            onClick={() => setEnd(video.current?.currentTime ?? duration)}
          >
            Position actuelle → fin
          </Button>
          <Button
            disabled={end <= start}
            onClick={() => setCuts((c) => [...c, { start, end }])}
          >
            Retirer la plage
          </Button>
          <Button
            disabled={!cuts.length}
            onClick={() => setCuts((c) => c.slice(0, -1))}
          >
            ↶ Annuler
          </Button>
        </div>
        <div className="timeline">
          {normalizeCuts(cuts, duration).map((c, i) => (
            <span
              key={i}
              style={{
                left: `${(c.start / duration) * 100}%`,
                width: `${((c.end - c.start) / duration) * 100}%`,
              }}
              title={`Retiré : ${c.start.toFixed(1)}–${c.end.toFixed(1)} s`}
            />
          ))}
        </div>
        <small>
          {cuts.length} plage(s) retirée(s) · {duration.toFixed(1)} secondes
        </small>
        <div className="toolbar"><label><input type="checkbox" checked={camera} disabled={item.recordingOptions?.camera!==true} onChange={e=>setCamera(e.target.checked)}/>Caméra</label><label><input type="checkbox" checked={clicks} disabled={item.recordingOptions?.clicks!==true} onChange={e=>setClicks(e.target.checked)}/>Clics</label><label><input type="checkbox" checked={keys} disabled={item.recordingOptions?.keystrokes!==true} onChange={e=>setKeys(e.target.checked)}/>Raccourcis</label><Button disabled={rendering} onClick={preview}>{rendering?"Préparation de l’aperçu…":"Prévisualiser le montage"}</Button></div>
        {renderError&&<p role="alert">{renderError}</p>}{rendered&&<div><p>Aperçu du montage : coupures, sources et volumes appliqués.</p><video controls src={mediaUrl(rendered)} style={{maxWidth:"100%",maxHeight:"40vh"}}/></div>}
        <div className="audio-gains">
          <label>
            Microphone · {mic}%
            <input
              type="range"
              min="0"
              max="200"
              value={mic}
              onChange={(e) => setMic(+e.target.value)}
            />
          </label>
          <label>
            Audio système · {system}%
            <input
              type="range"
              min="0"
              max="200"
              value={system}
              onChange={(e) => setSystem(+e.target.value)}
            />
          </label>
          <Button
            onClick={() =>
              run("export_video", {
                id: item.id,
                cuts: normalizeCuts(cuts, duration),
                microphoneGain: mic / 100,
                systemGain: system / 100,camera,clicks,keys,
              })
            }
          >
            Exporter MP4 ↗
          </Button>
        </div>
      </div>
    </>
  );
}
function Camera({ settings, recording }: { settings: Record<string, unknown>;recording:boolean }) {
  const ref = useRef<HTMLVideoElement>(null);
  const [error, setError] = useState("");
  const [frame, setFrame] = useState(0);
  const preview =
    typeof settings.cameraPreviewPath === "string"
      ? settings.cameraPreviewPath
      : "";
  useEffect(() => {
    if (!preview) return;
    const timer = window.setInterval(() => setFrame(Date.now()), 200);
    return () => window.clearInterval(timer);
  }, [preview]);
  useEffect(() => {
    if (preview) return;
    let stream: MediaStream | undefined;
    let cancelled = false;
    navigator.mediaDevices
      .getUserMedia({ video: true, audio: false })
      .then((s) => {
        if (cancelled) {
          s.getTracks().forEach((t) => t.stop());
          return;
        }
        stream = s;
        if (ref.current) ref.current.srcObject = s;
      })
      .catch((e) => setError(String(e)));
    return () => {
      cancelled = true;
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, [preview]);
  const shape = String(settings.cameraShape ?? "circle");
  const radius = shape === "square" ? "0" : shape === "rounded" ? "22%" : "50%";
  return (
    <div
      className="camera-preview"
      onPointerDown={async()=>{if(!recording){try{await getCurrentWindow().startDragging();await api("camera_position");}catch(e){setError(String(e));}}}}
      title="Position de caméra définie avant l’enregistrement"
      style={{
        borderRadius: radius,
        aspectRatio: shape === "verticalOval" ? "3 / 4" : shape === "rounded" ? "4 / 3" : "1 / 1",
      }}
    >
      {error ? (
        <div role="alert">{error}</div>
      ) : preview ? (
        <img
          src={`${mediaUrl(preview)}?frame=${frame}`}
          alt="Aperçu caméra en direct"
          style={{
            height: "100%",
            width: "100%",
            objectFit: "cover",
            transform: `scale(${Number(settings.cameraZoom ?? 1)})`,
          }}
        />
      ) : (
        <video
          ref={ref}
          autoPlay
          muted
          playsInline
          style={{
            transform: `scaleX(-1) scale(${Number(settings.cameraZoom ?? 1)})`,
          }}
        />
      )}
    </div>
  );
}
