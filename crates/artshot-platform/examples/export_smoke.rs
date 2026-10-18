use artshot_platform::media::*;
fn main() {
    let root = std::env::temp_dir().join("artshot-platform-smoke");
    std::fs::create_dir_all(&root).unwrap();
    let source = root.join("source.mkv");
    let output = root.join("output.mp4");
    let _ = std::fs::remove_file(&source);
    let _ = std::fs::remove_file(&output);
    assert!(std::process::Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=640x360:rate=30:duration=3",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x240:rate=30:duration=3",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=3",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=880:duration=3",
            "-map",
            "0:v",
            "-map",
            "1:v",
            "-map",
            "2:a",
            "-map",
            "3:a",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-c:a",
            "pcm_s16le"
        ])
        .arg(&source)
        .status()
        .unwrap()
        .success());
    std::fs::write(
        root.join("events.json"),
        r#"[{"time":0.5,"x":0.3,"y":0.4,"label":null},{"time":1.5,"x":0.6,"y":0.4,"label":null}]"#,
    )
    .unwrap();
    let manifest = TrackManifest {
        path: source,
        duration: 3.,
        width: 640,
        height: 360,
        camera: true,
        system_audio: true,
        microphone: true,
    };
    let edit = ExportOptions {
        cuts: vec![Cut { start: 1., end: 2. }],
        camera_shape: "verticalOval".into(),
        camera_zoom: 1.5,
        system_gain: 0.5,
        ..Default::default()
    };
    export_mp4("ffmpeg", &manifest, &edit, &output, None, None).unwrap();
    println!("{}", output.display());
}
