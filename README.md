# Lingua — English reader MVP

SwiftUI MVP for reading English books and learning vocabulary.

## Run

Create a new iOS App project in Xcode (SwiftUI, iOS 17+) and add the files from `Lingua/` to the target. The app has no third-party dependencies.

The importer is intentionally a UI-level MVP: it adds the selected EPUB to the library. `BookAnalyzer` contains the offline heuristic for the next integration step, where EPUB XHTML files are extracted and passed into the analyzer. Translation and speech are represented in the reader flow and can be connected to Apple frameworks or an API later.
