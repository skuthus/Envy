import Foundation

/// The starter templates Envy seeds into the Templates folder on first
/// launch, same as WelcomeContent seeds the welcome note. {{date}}, {{time}},
/// and {{title}} are substituted by NoteStore.create(title:fromTemplate:)
/// when a note is actually created from one of these.
enum TemplateContent {
    // The Daily Notes template's own name carries {{date}}, not just its
    // body — a note created from it is titled e.g. "Daily Notes July 11,
    // 2026" right away, matching how tools like Obsidian date-stamp daily
    // notes automatically rather than leaving you to rename "Daily Notes"
    // by hand every day.
    static let samples: [(name: String, body: String)] = [
        ("Daily Notes {{date}}", dailyNotes),
        ("To-Do List", toDoList),
        ("Study Notes", studyNotes),
    ]

    private static let dailyNotes = """
    # {{date}}

    ## Top Priorities
    -

    ## Notes


    ## Follow Up
    -
    """

    private static let toDoList = """
    # {{title}}

    - [ ]
    - [ ]
    - [ ]
    """

    private static let studyNotes = """
    # {{title}}

    ## Key Concepts


    ## Questions


    ## Summary

    """
}
