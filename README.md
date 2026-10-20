# BuKey

A small macOS utility that selects a keyboard layout once when you switch to an application.

- Choose any keyboard layout currently enabled in macOS for each application.
- **System** leaves the current layout unchanged.

BuKey does not interfere with subsequent manual layout changes inside the application.

BuKey can also correct text typed in the wrong Russian/English keyboard layout:

- Double-tap **Caps Lock** to correct the recently typed text.
- Press **Shift–Option–Space** to convert the current selection.
- Optionally enable conservative automatic correction from the menu.

Text correction requires **Accessibility** and **Input Monitoring** permissions. Application layout rules continue to work without those permissions.

## Why I built BuKey

For a long time, I was frustrated that Blender's keyboard shortcuts did not work as expected whenever my active keyboard layout was not English. Every time I switched to Blender, nothing seemed to work until I manually changed the layout. It was a small interruption, but it happened often enough to become genuinely annoying.

That is how BuKey came to be: a tiny utility that makes sure the right keyboard layout is already active when I switch to an application.

## Build

```sh
chmod +x build.sh
./build.sh
```

The built application will appear at `outputs/BuKey.app`.

To install, extract `outputs/BuKey.zip` and move the application to `/Applications`.
Enable automatic startup with **Launch at Login** in the application menu.
