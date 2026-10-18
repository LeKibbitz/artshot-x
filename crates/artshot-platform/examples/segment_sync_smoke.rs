use artshot_platform::media::*;
fn main() {
    let root = std::env::temp_dir().join("artshot-segment-sync-smoke");
    std::fs::create_dir_all(&root).unwrap();
    let segment = root.join("segment.mkv");
    let assembled = root.join("assembled.mkv");
    let _ = std::fs::remove_file(&segment);
    let _ = std::fs::remove_file(&assembled);
    assert!(std::process::Command::new("ffmpeg")
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=320x180:rate=30:duration=2",
            "-f",
            "lavfi",
            "-i",
            "testsrc2=size=160x120:rate=30:duration=2.4",
            "-map",
            "0:v",
            "-map",
            "1:v",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast"
        ])
        .arg(&segment)
        .status()
        .unwrap()
        .success());
    let primary = probe("ffprobe", &segment).unwrap();
    assert!((primary.duration - 2.).abs() < 0.001, "{primary:?}");
    concatenate("ffmpeg", &[segment.clone(), segment], &assembled).unwrap();
    let primary = probe("ffprobe", &assembled).unwrap();
    assert!((primary.duration - 4.).abs() < 0.001, "{primary:?}");
    println!(
        "Screen duration stays 4s despite two 2.4s camera segments: {}",
        assembled.display()
    );
}
