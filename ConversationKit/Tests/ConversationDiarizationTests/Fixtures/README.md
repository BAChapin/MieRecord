`three-voice-meeting.m4a`: 34 s synthetic meeting rendered with the macOS
voices Samantha, Daniel, and Fred (`say`), joined with 0.6 s pauses, then AAC
compressed. Ground truth (seconds):

| Line | Voice | Start | End |
|---|---|---|---|
| 1 | Samantha | 0.00 | 3.89 |
| 2 | Daniel | 4.49 | 9.20 |
| 3 | Fred | 9.80 | 14.99 |
| 4 | Samantha | 15.59 | 19.72 |
| 5 | Daniel | 20.32 | 24.54 |
| 6 | Fred | 25.14 | 29.85 |
| 7 | Samantha | 30.45 | 34.07 |

Synthetic voices are a smoke test of the integration, not an accuracy
benchmark. Two similar synthetic female voices (Samantha and Karen) were merged
into one speaker in a separate trial.
