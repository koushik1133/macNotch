# Converter tab: iLovePDF-style conversions that stay on this Mac

## What the user asked for

> "refer ilovepdf … add the conversions in here, drop here and the other format will pop up, they can drag and drop the place they want"

So the tab works like this: **drop files**, see **format buttons for what you dropped**, click one, and **drag the result out** to Finder, Mail, Slack or a browser. Nothing is uploaded. Every conversion runs on this Mac with Apple frameworks.

## Research: iLovePDF's tools and how people use them

iLovePDF ([ilovepdf.com](https://www.ilovepdf.com/)) groups its tools into six sections:

- **Organize PDF:** Merge, Split, Remove pages, Extract pages, Organize, Scan to PDF.
- **Optimize PDF:** Compress, Repair, OCR.
- **Convert to PDF:** JPG, Word, PowerPoint, Excel, HTML.
- **Convert from PDF:** JPG, Word, PowerPoint, Excel, PDF/A.
- **Edit PDF:** Rotate, Page numbers, Watermark, Crop, Edit, Forms.
- **PDF Security:** Unlock, Protect, Sign, Redact, Compare.

It also has a newer "PDF Intelligence" section: Summarize, Translate, and PDF to Markdown.

On the website you choose a tool first, then upload files, then set options and download. Choosing the tool first does not fit a 508×114 pt drawer, so this tab turns that order around: **drop first, then pick from the targets that fit the input**. That is the "other formats pop up" behavior the user described. Options live in one compact "More…" menu. When an option needs text (a password, watermark text or page ranges), a small inline prompt replaces the format row.

## Mapping each tool to on-device Apple frameworks

| iLovePDF tool | On device? | How it is done here |
|---|---|---|
| Merge PDF | Yes | `PDFDocument.insert(_:at:)` with copied `PDFPage`s. Images and documents in the same drop become pages too. |
| Split PDF | Yes | One page per file, or one file per range ("1-3, 5, 8-"). |
| Extract / Remove pages | Yes | A page-range selection is written to a new `PDFDocument`. Listing pages in a different order also reorders them (a light version of "Organize"). |
| Organize PDF | Partly | Reordering works through Extract with an ordered range. There is no thumbnail grid, because the drawer is too small for one. |
| Compress PDF | Yes | A `QuartzFilter` built from the same keys as `/System/Library/Filters/Reduce File Size.qfilter` (JPEG quality and target image DPI), passed to `PDFDocument.write(to:withOptions:)` under the `"QuartzFilter"` key (PDFDocument.h, lines 199-200). Three presets. The second fallback is `PDFDocumentSaveImagesAsJPEGOption` + `OptimizeImagesForScreenOption` (macOS 13.4+). If neither result is smaller, the original is kept. The size before and after is always reported. Text stays selectable. |
| Repair PDF | Partly | The PDF is reopened with PDFKit and written again, which rebuilds the xref table and object streams. Badly broken files fail with a clear error. |
| OCR PDF | Yes | Vision's `VNRecognizeTextRequest` reads each page that has no text. The recognized lines are then drawn back over the page as **invisible text** (`CGContext.setTextDrawingMode(.invisible)`) at Vision's bounding boxes, so the PDF becomes searchable and selectable. |
| JPG to PDF | Yes | A CoreGraphics PDF context. Page size is Fit (from the image's pixels and DPI), A4 or Letter, with automatic orientation. JPEGs are passed through without re-encoding. HEIC and other formats are re-encoded once as JPEG (quality 0.9). PNGs stay lossless. |
| Word to PDF | Yes | `NSAttributedString` reads `.officeOpenXML` (.docx), `.docFormat` (.doc), `.rtf`, `.rtfd`, `.openDocument` (.odt), `.wordML` and plain text. The text is paginated off screen with TextKit 1 (`NSLayoutManager` with one `NSTextContainer` per page) into a CoreGraphics PDF context. The document's own paper size and margins are used when it has them. |
| HTML to PDF | Files only | Runs `/usr/bin/textutil -noload -convert rtf`, which loads no remote resources, then follows the Word path. Converting a URL would need a `WKWebView` on the main thread, so it is not built yet. |
| Excel to PDF | CSV, TSV, XLSX | CSV and TSV use a parser that handles quoted fields. XLSX is read with `/usr/bin/unzip -p` (sharedStrings plus every worksheet) and `XMLParser`. The result is drawn as a grid with a repeating header row; wide sheets get landscape pages. There are no formulas, charts or cell styling. |
| PowerPoint to PDF | Text only | The `<a:t>` runs of each `ppt/slides/slideN.xml` become one landscape page per slide. Layouts and pictures are not rendered. A full render would need Keynote or PowerPoint. |
| PDF to JPG | Yes | Each page is rendered with `PDFPage.draw(with:to:)` into a bitmap `CGContext` at the chosen DPI (72, 150 or 300). Images are written with ImageIO as JPG or PNG. |
| PDF to Word | Yes | `PDFPage.attributedString` for each page. Scanned pages go through Vision OCR. The output is a `.docx` written with `NSAttributedString.data(from:documentAttributes:[.documentType: .officeOpenXML])`. Expect plain styling, with no layout reconstruction. |
| PDF to TXT / Markdown | Yes (TXT) | `PDFPage.string`, with OCR as a fallback. |
| PDF to PowerPoint / Excel | No | There is no Apple writer for .pptx or .xlsx, and rebuilding tables from a PDF is not reliable. Possible later: write a .pptx by hand with one image per slide. |
| PDF to PDF/A | No | Quartz has no PDF/A writer. The only system filter is PDF/X-3. |
| Rotate PDF | Yes | `PDFPage.rotation` changes by 90, 180 or 270 degrees, for every page or for a page range. |
| Page numbers | Yes | The page is redrawn into a new PDF context, so vector text stays vector. A CoreText `CTLine` adds the number at the bottom center or bottom right ("1" or "1 / 12"). |
| Watermark | Yes | Text drawn diagonally across the page with CoreText, at the chosen opacity. |
| Protect PDF | Yes | `PDFDocument.write(to:withOptions:[.userPasswordOption, .ownerPasswordOption])`. |
| Unlock PDF | Yes, with the password | `PDFDocument.unlock(withPassword:)`, then the file is written again without encryption. If the result is still encrypted, the pages are redrawn as a fallback. |
| Crop, Edit, Forms, Sign, Redact, Compare | Not here | These need an interactive page canvas. Preview.app does them well. Redact and Compare could be built later with `PDFDocument.findString` and Vision. |
| Scan to PDF | Not here | This would need Continuity Camera (`NSMenuItem.importFromDeviceIdentifier`) in a key window. |
| Summarize, Translate | Elsewhere | The Tray already has AI actions. Use "Add to Tray", then ✨. |
| Images (extra) | Yes | Converts between JPG, PNG, HEIC, TIFF and AVIF, and resizes to a longest side, all with ImageIO. **WebP can be read but not written:** `CGImageDestinationCopyTypeIdentifiers()` on macOS 27 lists jpeg, png, gif, tiff, jp2, heic, heics, avif, ico, bmp, icns, psd, pdf, tga, exr, pbm and pvr, but no webp. So "→ WebP" is never offered. |
| PDF thumbnails | Yes | PNG renders of each page with the longest side at 320 px. |

## Sources

- iLovePDF tool list: https://www.ilovepdf.com/
- PDFKit `PDFDocumentWriteOption` (owner and user password, `SaveImagesAsJPEG`, `OptimizeImagesForScreen`, `SaveTextFromOCR`) and the `"QuartzFilter"` write-option key: `PDFKit.framework/Headers/PDFDocument.h` in the macOS SDK (lines 91-105 and 199-213); https://developer.apple.com/documentation/pdfkit/pdfdocumentwriteoption
- `QuartzFilter(properties:)`, `applyToContext:`: `Quartz.framework/Frameworks/QuartzFilters.framework/Headers/QuartzFilter.h`; the preset keys come from `/System/Library/Filters/Reduce File Size.qfilter` (`plutil -p`).
- `NSAttributedString.DocumentType.officeOpenXML` and the other types: `AppKit.framework/Headers/NSAttributedString.h` (lines 262-271); https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype/officeopenxml
- TextKit 1 on background threads: Apple's "Text System Overview" notes that NSLayoutManager may be used off the main thread when only one thread uses it. https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextLayout/
- Vision `VNRecognizeTextRequest`: https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- ImageIO write support: `CGImageDestinationCopyTypeIdentifiers()`, checked on this machine.
- `textutil(1)` (`-convert`, `-noload`, `-stdout`): `man textutil`.

## Architecture (Sources/Labs/Converter)

- `ConverterModels.swift`: Sendable value types. `ConverterInputKind`, `ConverterImageFormat`, `ConverterOp`, `ConverterOptions` and `ConverterOutput`, plus the errors and the page-range parser.
- `ConverterEngine.swift`: detection, the target list and the entry point `run(_:inputs:options:in:progress:)`. All of it is synchronous, nonisolated and called from `Task.detached`. It checks `Task.isCancelled` between pages.
- `ConverterPDFOps.swift`, `ConverterImageOps.swift`, `ConverterDocumentOps.swift`, `ConverterOCR.swift`: the operations themselves.
- `ConverterController.swift`: `@MainActor ObservableObject`. It holds the inputs, the targets, the options, the jobs (with progress and cancel) and the results, posts a LiveActivity when a job finishes, and exposes `onAddToTray`.
- `ConverterTabView.swift`: the drawer UI. Result cards use the Tray's `TrayDragSource` and `TrayDragSourceView`, so drags out are real `NSDraggingSession`s that work in every app.

Outputs go to `~/Library/Application Support/SparkV/Converted/<yyyy-MM-dd HH.mm.ss>-<op>/`. Dropped image data (screenshot thumbnails) is staged in `Converted/Inputs/`.

## Test results (harness on generated inputs, 69 of 69 checks passed)

The test inputs were generated: text PDFs drawn with CoreGraphics and CoreText, a scanned-style PDF made from a single bitmap, a 4.3 MB PDF holding a lossless image, a page with /Rotate 90, a password-locked PDF, PNG (with alpha), JPG (including EXIF orientation 6) and HEIC images, a .docx written through `.officeOpenXML`, plus RTF, HTML, TXT, Markdown, CSV (quoted fields), XLSX (two sheets, shared and inline strings) and PPTX files, the last two zipped by hand.

- PDF → JPG at 150 dpi gives 1275×1650 px. A rotated page renders landscape at 792×612, and its corners end up in the correct places.
- PDF → TXT and PDF → Word pick up text through OCR on the scanned page. The `.docx` files can be read back. The OCR'd PDF is searchable (`findString` finds the invoice number).
- Compress shrinks the 4.3 MB test PDF to 2.3 MB on Less, 944 KB on Recommended and 350 KB on Extreme. Text stays selectable at every level.
- Merge of 2 PDFs, a PNG, a JPG and a .docx produces a 9-page PDF. Split works per page and per range ("1-2, 3"). Extract with "3,1" reorders pages. Remove deletes page 2.
- Rotate can target page 2 only. Page numbers ("2 / 3") and watermark text appear in the PDF's text. Protect locks the file and unlocks with the password. Unlock rejects a wrong password and otherwise removes encryption.
- Images → PDF on A4 gives a landscape page for a wide photo and a portrait page for an EXIF-rotated photo. The JPEGs are passed through and the HEIC is re-encoded, so the output is 1.3 MB from 1.2 MB of inputs.
- HEIC → JPG, PNG → JPG (transparency flattened to white), JPG (EXIF 6) → PNG (upright), and → HEIC, AVIF and TIFF all work. Resize gives 800×600.
- DOCX → a 3-page PDF with the title on page 1. RTF, HTML (including its table), TXT (5 pages) and Markdown → PDF all work. MD → DOCX and RTF → DOCX can be read back. CSV → a 3-page table, and XLSX → 2 sheets. PPTX → 3 slide pages.
- Cancelling the task throws `CancellationError`. Progress is reported per page.

**Known cost: Vision's first text request in a new process took 69 to 86 seconds once per binary** (model warm-up). After that it takes about 0.3 seconds per page. The job card shows progress and can be cancelled while it waits.
