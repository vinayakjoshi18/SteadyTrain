# SteadyTrain

A menu bar app that watches your head through the webcam and nudges one window to cancel the shake you feel on a train.

## How it works

1. **Camera + Vision** find your eyes, eyebrows and nose in every frame (rigid parts of the face, so talking doesn't count as movement).
2. **One Euro filter** removes landmark jitter.
3. **Baseline removal** subtracts slow movement (leaning, slouching), leaving only shake.
4. **Prediction** adds velocity × measured lag, because by the time a frame is processed your head has already moved on.
5. **Window move** through the Accessibility API. The window follows your head relative to the screen, so the text stays put in your view. 1 mm of head shake moves the window 1 mm on screen (at strength 1.0).

## Build and run

Needs macOS 13+ and Xcode command line tools.

```bash
cd SteadyTrain
chmod +x build_app.sh
./build_app.sh
open build/SteadyTrain.app
```

First launch asks for the camera. The first time you lock a window it asks for Accessibility (System Settings > Privacy & Security > Accessibility).

Ad-hoc signed builds lose the Accessibility permission on every rebuild. Remove SteadyTrain from the list and add it again, or build with a real identity: `SIGN_ID="Apple Development: ..." ./build_app.sh`.

## Using it

- Click the tram icon in the menu bar.
- **Steady a window**, then click the window you want within 3 seconds. Or press **⌃⌥S** inside any window to lock or release it.
- Drag the locked window anytime: it adopts the new spot as home.

## Test at your desk before the train

1. Lock a window and slowly sway your head left and right.
2. The window should move **with** your head (so the text stays still in your view). If it moves the opposite way, tick **Flip left/right**. Same for up/down.
3. Switch **Move the window** off to just watch the graph and shake readout without moving anything.

## Tuning on the train

| Slider | What it does | If… |
|---|---|---|
| Strength | Scale of the correction | Over-corrects: lower it. Text still drifts the same way as the shake: raise it |
| Max shift | Cap on how far the window moves | Big bumps fling the window: lower it |
| Ignore movement slower than | Separates shake from you moving | Window wanders when you lean: raise it. Slow sway not corrected: lower it |
| Extra lookahead | Predicts further ahead | Correction feels late: raise it. Window looks jittery: lower it |

## Honest limits

- Built-in Mac cameras usually run at 30 fps, and total lag is around 50 to 80 ms. That's fine for slow sway (below ~2 Hz). Fast buzz from the rails will not be cancelled, and without prediction a late correction can make things worse.
- Some apps (Electron apps especially) move their windows slowly through Accessibility, which adds lag.
- Head rotation (nodding) is treated roughly like translation.
- Low light in the train means longer camera exposure, more motion blur and noisier tracking.

## License

MIT. See [LICENSE](LICENSE).
