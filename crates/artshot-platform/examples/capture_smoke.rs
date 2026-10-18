fn main() -> artshot_platform::Result<()> {
    let displays = artshot_platform::list_displays()?;
    println!("{}", serde_json::to_string(&displays)?);
    let first = displays
        .first()
        .ok_or_else(|| artshot_platform::Error::Native("No displays".into()))?;
    let path = std::env::temp_dir().join("artshot-native-capture-smoke.png");
    let mut native = artshot_platform::NativeBridge::spawn(
        "crates/artshot-platform/native/macos/artshot-native",
    )?;
    native.capture_png(
        first.id,
        Some(artshot_platform::Region {
            x: 10,
            y: 10,
            width: 128,
            height: 96,
        }),
        &path,
        std::process::id(),
    )?;
    let image = image::open(&path)?;
    assert_eq!(image.width(), 128);
    assert_eq!(image.height(), 96);
    println!("{}", path.display());
    Ok(())
}
