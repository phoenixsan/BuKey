# BuKey

A small macOS utility that selects a keyboard layout once when you switch to an application.

- **Ru** — select the Russian layout when switching to the application.
- **En** — select the English layout.
- **System** — leave the current layout unchanged.

BuKey does not interfere with subsequent manual layout changes inside the application.

## Build

```sh
chmod +x build.sh
./build.sh
```

The built application will appear at `outputs/BuKey.app`.

To install, extract `outputs/BuKey.zip` and move the application to `/Applications`.
Enable automatic startup with **Launch at Login** in the application menu.
