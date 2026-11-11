# Timing how smooth Animus is

Animus Dev (`./build-dev.sh`) keeps a log of every moment the app was too busy
to draw: `~/Library/Application Support/Animus Dev/hitches.log`
(see `Sources/StudyApp/HitchLog.swift`). The real app never does this.

Drive it without touching the window, so the timings are the app's own:

    swiftc -O scripts/perf/poke.swift -o /tmp/poke
    /tmp/poke home deck study home browse stats addcards     # opens each page, 1.5 s apart
    /tmp/poke scroll                                         # scrolls the page down and back
    /tmp/poke space                                          # Space while studying
    /tmp/poke count                                          # how many views the page is made of
    grep busy ~/Library/Application\ Support/Animus\ Dev/hitches.log

Each `busy` line is one page switch: the work it took, and every frame that
took 8 ms or more (a frame has 16.7 ms at 60 a second).

Don't click or screenshot the window while timing: the screen tools ask the
app questions of their own, which shows up as freezes that aren't Animus's.
Keep the Mac awake (`caffeinate -i`), or a nap in the middle ruins the numbers.
