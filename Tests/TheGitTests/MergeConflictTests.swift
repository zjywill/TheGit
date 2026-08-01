import XCTest
@testable import TheGit

/// The merge editor's foundation: marker parsing and result assembly.
/// Both write the user's file back to disk on Save, so a subtle slip —
/// a swallowed line, a phantom newline — is data loss, not a glitch.
final class MergeConflictTests: XCTestCase {
    private let simple = """
        top
        <<<<<<< HEAD
        ours line
        =======
        theirs line
        >>>>>>> main
        bottom
        """ + "\n"

    private func file() -> FileChange {
        FileChange(path: "a.swift", status: "U", area: .unstaged)
    }

    // MARK: - Parsing

    func testParsesSimpleConflict() throws {
        let doc = try XCTUnwrap(ConflictDocument.parse(simple))
        XCTAssertEqual(doc.conflicts.count, 1)
        XCTAssertEqual(doc.conflicts[0].ours, ["ours line"])
        XCTAssertEqual(doc.conflicts[0].theirs, ["theirs line"])
        XCTAssertEqual(doc.conflicts[0].oursLabel, "HEAD")
        XCTAssertEqual(doc.conflicts[0].theirsLabel, "main")
        XCTAssertEqual(doc.segments, [.shared(["top"]), .conflict(0), .shared(["bottom"])])
        XCTAssertTrue(doc.endsWithNewline)
    }

    func testNoMarkersMeansNoDocument() {
        XCTAssertNil(ConflictDocument.parse("plain\ntext\n"))
        XCTAssertNil(ConflictDocument.parse(""))
    }

    /// diff3/zdiff3 writes a ||||||| base section; it belongs to neither
    /// side and never to the output.
    func testDiff3BaseSectionIsDropped() throws {
        let text = """
            <<<<<<< HEAD
            ours
            ||||||| merged common ancestors
            base
            =======
            theirs
            >>>>>>> topic
            """ + "\n"
        let doc = try XCTUnwrap(ConflictDocument.parse(text))
        XCTAssertEqual(doc.conflicts[0].ours, ["ours"])
        XCTAssertEqual(doc.conflicts[0].theirs, ["theirs"])
        XCTAssertEqual(doc.conflicts[0].base, ["base"])
    }

    /// A file that ends mid-block (markers that were never git's) must
    /// keep those lines as plain text — nothing may vanish on save.
    func testTruncatedBlockFallsBackToText() throws {
        let text = simple + "<<<<<<< HEAD\ndangling\n"
        let doc = try XCTUnwrap(ConflictDocument.parse(text))
        XCTAssertEqual(doc.conflicts.count, 1)
        XCTAssertEqual(
            doc.segments.last,
            .shared(["bottom", "<<<<<<< HEAD", "dangling"])
        )
        // And a file that is ONLY a truncated block has no conflicts at all.
        XCTAssertNil(ConflictDocument.parse("<<<<<<< HEAD\nours\n=======\n"))
    }

    func testMissingTrailingNewlineIsPreserved() throws {
        let doc = try XCTUnwrap(ConflictDocument.parse(String(simple.dropLast())))
        XCTAssertFalse(doc.endsWithNewline)
    }

    /// One side empty: the incoming branch added lines the current one
    /// doesn't have. The block still gets an aligned row (the checkbox
    /// lives on it) and "take nothing from A" resolves it.
    @MainActor
    func testEmptySideStillDecidable() throws {
        let text = """
            <<<<<<< HEAD
            =======
            added
            >>>>>>> main
            """ + "\n"
        let doc = try XCTUnwrap(ConflictDocument.parse(text))
        XCTAssertEqual(doc.conflicts[0].ours, [])
        let session = MergeEditorSession(
            file: file(), document: doc, encoding: .utf8, originalData: Data()
        )
        let row = try XCTUnwrap(session.alignedRows.first)
        XCTAssertNil(row.left)
        XCTAssertNotNil(row.right?.ref)
        XCTAssertTrue(row.opensConflict)

        XCTAssertEqual(session.sideState(0, side: .ours), .none)
        session.setSide(0, side: .ours, on: true)
        // Zero lines to take, but the conflict is now decided.
        XCTAssertEqual(session.sideState(0, side: .ours), .all)
        XCTAssertTrue(session.allResolved)
        XCTAssertEqual(session.resolvedContent(), "")
    }

    // MARK: - Taking and output

    /// GitKraken's rule, verified against GitKraken itself: the output
    /// order is the order things were TAKEN, not a fixed A-then-B.
    @MainActor
    func testOutputFollowsClickOrder() throws {
        let text = """
            top
            <<<<<<< HEAD
            o1
            o2
            =======
            t1
            >>>>>>> main
            bottom
            """ + "\n"
        let doc = try XCTUnwrap(ConflictDocument.parse(text))
        let session = MergeEditorSession(
            file: file(), document: doc, encoding: .utf8, originalData: Data()
        )

        XCTAssertFalse(session.allResolved)
        // Take B first, then A: B's line must come out on top.
        session.setSide(0, side: .theirs, on: true)
        XCTAssertTrue(session.allResolved)
        session.setSide(0, side: .ours, on: true)
        XCTAssertEqual(session.resolvedContent(), "top\nt1\no1\no2\nbottom\n")

        // A single line taken later lands at the end of the block.
        session.toggleLine(ConflictLineRef(conflict: 0, side: .ours, line: 0))  // untake o1
        XCTAssertEqual(session.resolvedContent(), "top\nt1\no2\nbottom\n")
        session.toggleLine(ConflictLineRef(conflict: 0, side: .ours, line: 0))  // retake o1
        XCTAssertEqual(session.resolvedContent(), "top\nt1\no2\no1\nbottom\n")
        XCTAssertEqual(session.sideState(0, side: .ours), .all)

        // Untaking everything is still "resolved" — an explicit delete.
        session.setSide(0, side: .ours, on: false)
        session.setSide(0, side: .theirs, on: false)
        XCTAssertTrue(session.allResolved)
        XCTAssertEqual(session.resolvedContent(), "top\nbottom\n")

        // Reset forgets the decisions entirely.
        session.reset()
        XCTAssertFalse(session.allResolved)
    }

    @MainActor
    func testWholeSideCheckboxSpansConflicts() throws {
        let text = """
            <<<<<<< HEAD
            a-ours
            =======
            a-theirs
            >>>>>>> main
            mid
            <<<<<<< HEAD
            b-ours
            =======
            b-theirs
            >>>>>>> main
            """ + "\n"
        let doc = try XCTUnwrap(ConflictDocument.parse(text))
        let session = MergeEditorSession(
            file: file(), document: doc, encoding: .utf8, originalData: Data()
        )

        XCTAssertEqual(session.wholeSideState(.ours), .none)
        session.setWholeSide(.ours, on: true)
        XCTAssertEqual(session.wholeSideState(.ours), .all)
        XCTAssertTrue(session.allResolved)
        XCTAssertEqual(session.resolvedContent(), "a-ours\nmid\nb-ours\n")

        // Output rows renumber live, carry their side, and an untouched
        // conflict leaves a marker row with no number.
        session.choices[1] = nil
        let rows = session.outputLines
        XCTAssertEqual(rows.map(\.text), ["a-ours", "mid", ""])
        XCTAssertEqual(rows[0].side, .ours)
        XCTAssertEqual(rows.last?.kind, .unresolved)
        XCTAssertEqual(rows.compactMap(\.number), [1, 2])
    }

    /// The #6 fallback: hand-editing the output. The seed keeps an
    /// untouched conflict's ORIGINAL markers in place, the marker guard
    /// holds Save until they're gone, and Save writes the draft verbatim.
    @MainActor
    func testHandEditFallback() throws {
        let text = """
            top
            <<<<<<< HEAD
            ours line
            =======
            theirs line
            >>>>>>> main
            mid
            <<<<<<< HEAD
            o2
            =======
            t2
            >>>>>>> main
            bottom
            """ + "\n"
        let doc = try XCTUnwrap(ConflictDocument.parse(text))
        let session = MergeEditorSession(
            file: file(), document: doc, encoding: .utf8, originalData: Data()
        )

        // Conflict 1 picked, conflict 2 untouched: the seed has real
        // text for the first and the untouched markers for the second.
        session.setSide(0, side: .theirs, on: true)
        session.beginEditing()
        XCTAssertEqual(session.editableContent(), """
            top
            theirs line
            mid
            <<<<<<< HEAD
            o2
            =======
            t2
            >>>>>>> main
            bottom
            """ + "\n")

        // Markers still present: the gate holds.
        XCTAssertTrue(session.isEditing)
        XCTAssertTrue(session.draftHasMarkers)
        // Save remains available so a legitimate marker literal is not a
        // permanent trap; RepoState presents an explicit warning first.
        XCTAssertTrue(session.canSave)

        // The user resolves by hand — a mix no checkbox could produce.
        session.draft = "top\ntheirs line\nmid\no2 and t2, merged by hand\nbottom\n"
        XCTAssertFalse(session.draftHasMarkers)
        XCTAssertTrue(session.canSave)
        XCTAssertEqual(session.resolvedContent(), "top\ntheirs line\nmid\no2 and t2, merged by hand\nbottom\n")

        // Cancel throws the draft away and the pick state is untouched.
        session.cancelEditing()
        XCTAssertFalse(session.isEditing)
        XCTAssertFalse(session.canSave)  // conflict 2 still unresolved
        XCTAssertEqual(session.resolvedContent(), "top\ntheirs line\nmid\nbottom\n")
    }

    @MainActor
    func testHandEditRecognizesDiff3AndPartialMarkerLines() throws {
        let doc = try XCTUnwrap(ConflictDocument.parse(simple))
        let session = MergeEditorSession(
            file: file(), document: doc, encoding: .utf8, originalData: Data()
        )
        session.beginEditing()

        for marker in [
            "<<<<<<< HEAD",
            "||||||| merged common ancestors",
            "=======",
            ">>>>>>> main",
            "<<<<<<<",
        ] {
            session.draft = "ordinary\n\(marker)\ntext\n"
            XCTAssertTrue(session.draftHasMarkers, "missed marker: \(marker)")
        }

        session.draft = "let value = \"<<<<<<<not a marker\"\n"
        XCTAssertFalse(session.draftHasMarkers)
    }

    @MainActor
    func testDirtyStateDistinguishesOpeningFromChangingHandEdit() throws {
        let doc = try XCTUnwrap(ConflictDocument.parse(simple))
        let session = MergeEditorSession(
            file: file(), document: doc, encoding: .utf8, originalData: Data()
        )

        XCTAssertFalse(session.hasUnsavedChanges)
        session.beginEditing()
        XCTAssertFalse(session.handEditIsDirty)
        XCTAssertFalse(session.hasUnsavedChanges)

        session.draft?.append("// changed\n")
        XCTAssertTrue(session.handEditIsDirty)
        XCTAssertTrue(session.hasUnsavedChanges)

        session.cancelEditing()
        session.setSide(0, side: .ours, on: true)
        XCTAssertTrue(session.hasUnsavedChanges)
    }

    /// The aligned rows both columns scroll as one: shared lines carry
    /// both cells, blocks pad the shorter side with nil fillers, and
    /// each column numbers its own version of the file.
    @MainActor
    func testAlignedRowsPadTheShorterSide() throws {
        let text = """
            top
            <<<<<<< HEAD
            o1
            o2
            =======
            t1
            >>>>>>> main
            bottom
            """ + "\n"
        let doc = try XCTUnwrap(ConflictDocument.parse(text))
        let session = MergeEditorSession(
            file: file(), document: doc, encoding: .utf8, originalData: Data()
        )
        let rows = session.alignedRows
        XCTAssertEqual(rows.count, 4)  // top, o1|t1, o2|filler, bottom

        XCTAssertEqual(rows[0].left?.text, "top")
        XCTAssertEqual(rows[0].right?.text, "top")
        XCTAssertNil(rows[0].conflict)

        XCTAssertEqual(rows[1].left?.text, "o1")
        XCTAssertEqual(rows[1].right?.text, "t1")
        XCTAssertTrue(rows[1].opensConflict)

        XCTAssertEqual(rows[2].left?.text, "o2")
        XCTAssertNil(rows[2].right)

        // Per-side numbering: A's bottom is line 4, B's is line 3.
        XCTAssertEqual(rows[3].left?.number, 4)
        XCTAssertEqual(rows[3].right?.number, 3)
    }
}
