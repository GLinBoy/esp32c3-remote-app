# Contributing to ESP32C3 Remote App

## Development Workflow

1. **Clone repository**:

   ```bash
   git clone git@github.com:GLinBoy/esp32c3-remote-app.git
   cd esp32c3-remote-app
   ```

2. **Install dependencies**:

   ```bash
   flutter pub get
   ```

3. **Create feature branch**:

   ```bash
   git checkout -b feature/my-feature
   ```

4. **Run on device/emulator**:

   ```bash
   flutter run
   ```

5. **Test before committing**:

   ```bash
   flutter analyze
   flutter test
   ```

6. **Commit with conventional commits**:

   ```bash
   git commit -m "feat: add new feature description"
   ```

7. **Push and create PR**:

   ```bash
   git push -u origin feature/my-feature
   ```

   Open PR on GitHub, CI will run analyze + test.

## Releasing

Only maintainers create releases:

```bash
git checkout main
git pull
git tag v1.x.x
git push origin v1.x.x
```

GitHub Actions automatically builds and publishes signed release APK.
