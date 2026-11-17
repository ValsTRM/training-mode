# Training Mode

One click to set this PC up for long ML training runs, an optional calm, energy-saving mode once training is done, and one click to put everything back.

## Use it

1. Double-click **`Training Mode.cmd`**. Windows asks for admin once; that's needed for the GPU power cap.
2. Pick a GPU power cap. 75% is the default, and 100% keeps stock speed.
3. Click **Start training mode**, then start your training.
4. When training is done, the app moves on by itself once the GPU has been idle for 15 minutes (if "Treat training as done" is ticked). You can also click **Training done** yourself.
   - With **"After training is done, optimize energy (Calm mode)"** ticked, it switches to Calm mode instead of going back to your normal plan.
   - Otherwise it goes straight back to normal.
5. Click **Back to normal** when you want your usual setup back, for example before gaming.

Minimizing the window sends it to the system tray. It keeps watching from there, and the tray menu has every switch.

## The three modes

| Mode | Power plan | GPU | Tray icon |
|---|---|---|---|
| **Normal** | Your own plan (e.g. Ultimate Performance), untouched | Your normal limit | gray |
| **Training** | Temporary copy "Training Mode (temporary)": never sleeps or hibernates, display off after N min, CPU can idle down (min 5%, energy preference 25, the Windows Balanced values) | Capped at the % you pick | green |
| **Calm** | Temporary copy "Calm Mode (temporary)": CPU prefers efficiency (min 5%, energy preference 60, the Windows Power saver values, with no speed cap), display off after N min, sleep as in your normal plan | Back to your normal limit | teal |

Calm mode is meant for after everything's done, or for light and remote work: the PC stays on and responsive but stops running full blast. It stays on until you click Back to normal, even if you close the app.

## How "Back to normal" undoes everything

- Your original power plan is made active again, and both temporary copies are deleted. Your own plans are never edited.
- The GPU limit you had before is restored. A restart also resets it.

Before changing anything, the app saves your original settings to `%LOCALAPPDATA%\TrainingMode\state.json`. That folder also holds `settings.json` (your last choices) and `log.txt`.

**If the PC restarts while training or Calm mode is on**, the power plan switches back to normal at the next sign-in by itself. This works through a one-time Windows "RunOnce" entry that deletes itself after it runs. The next time you open the app, it finishes the cleanup.

## Command line (optional)

```bat
"Training Mode.cmd" on
"Training Mode.cmd" on -GpuPercent 70 -DisplayOffMinutes 10
"Training Mode.cmd" done
"Training Mode.cmd" calm
"Training Mode.cmd" off
"Training Mode.cmd" status
```

`done` means training is finished: it goes to Calm mode or to normal, depending on the checkbox setting.

## Notes

- **Game boosters such as Razer Cortex can switch the power plan.** If one does while training or Calm mode is on, the window shows a warning with a "Re-apply" link.
- **Is the cap actually doing anything?** Check the live readout. If the GPU draws well under the cap (common with small models or slow data loading), the cap isn't slowing anything down. If it sits at the cap and your run takes noticeably longer, raise it.
- **Removing it:** click Back to normal, then delete this folder and `%LOCALAPPDATA%\TrainingMode`.
