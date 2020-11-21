//
//  FileSystemEventManager.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 7/13/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Foundation
import FSNotesCore_macOS

class FileSystemEventManager {
    private var storage: Storage
    private var delegate: ViewController
    private var watcher: FileWatcher?
    private var observedFolders: [String]
    
    init(storage: Storage, delegate: ViewController) {
        self.storage = storage
        self.delegate = delegate
        self.observedFolders = self.storage.getProjectPaths()
    }
    
    public func start() {
        watcher = FileWatcher(self.observedFolders)
        watcher?.callback = { event in
            if UserDataService.instance.fsUpdatesDisabled {
                return
            }
            
            guard let path = event.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return
            }
            
            guard let url = URL(string: "file://" + path) else {
                return
            }

            if !event.path.contains(".textbundle") && (
                event.dirRemoved || event.dirCreated || event.dirRenamed
            ) {
                self.handleDirEvents(event: event)
                return
            }

            if !self.storage.allowedExtensions.contains(url.pathExtension) && !self.storage.isValidUTI(url: url) {
                return
            }
            
            if event.fileRemoved || event.dirRemoved {
                guard let note = self.storage.getBy(url: url) else { return }
                
                self.removeNote(note: note)
            }
            
            if event.fileRenamed || event.dirRenamed {
                self.moveHandler(url: url, pathList: self.observedFolders)
                return
            }
            
            guard self.checkFile(url: self.handleTextBundle(url: url), pathList: self.observedFolders) else {
                return
            }
            
            // Order is important, invoke only before change
            if event.fileCreated {
                self.importNote(self.handleTextBundle(url: url))
                return
            }
            
            if event.fileChange,
                let note = self.storage.getBy(url: self.handleTextBundle(url: url))
            {
                self.reloadNote(note: note)
            }
        }
        
        watcher?.start()
    }

    private func handleDirEvents(event: FileWatcherEvent) {
        guard !event.path.contains("Trash") else { return }

        let dirURL = URL(fileURLWithPath: event.path, isDirectory: true)
        let project = self.storage.getProjectBy(url: dirURL)

        let srcProject = self.storage.getProjects().first(where: { $0.moveSrc == dirURL })
        let dstProject = self.storage.getProjects().first(where: { $0.moveDst == dirURL })

        if event.dirRenamed {
            if let project = project {
                if dstProject != nil {
                    dstProject?.moveDst = nil
                } else {

                    // hack: occasionally get rename event when created
                    if !FileManager.default.fileExists(atPath: dirURL.path) {
                        self.delegate.sidebarOutlineView.removeProject(project: project)
                    }
                }
            } else {
                if srcProject != nil {
                    srcProject?.moveSrc = nil
                } else {
                    self.delegate.sidebarOutlineView.insertProject(url: dirURL)
                }
            }
            return
        }

        if event.dirRemoved  {
            if let project = project {
                self.delegate.sidebarOutlineView.removeProject(project: project)
            }
            return
        }

        if event.dirCreated {
            self.delegate.sidebarOutlineView.insertProject(url: dirURL)
            return
        }
    }
    
    private func moveHandler(url: URL, pathList: [String]) {
        let fileExistInFS = self.checkFile(url: url, pathList: pathList)
        
        guard let note = self.storage.getBy(url: url) else {
            if fileExistInFS {
                self.importNote(url)
            }
            return
        }
        
        if fileExistInFS {
            renameNote(note: note)
            return
        }
        
        removeNote(note: note)
    }
    
    private func checkFile(url: URL, pathList: [String]) -> Bool {
        return (
            FileManager.default.fileExists(atPath: url.path)
            && (
                self.storage.allowedExtensions.contains(url.pathExtension)
                || self.storage.isValidUTI(url: url)
            )
            && pathList.contains(url.deletingLastPathComponent().path)
        )
    }
    
    private func importNote(_ url: URL) {
        let url = self.handleTextBundle(url: url)

        let n = storage.getBy(url: url)
        guard n == nil else {
            if let nUnwrapped = n, nUnwrapped.url == UserDataService.instance.focusOnImport {
                self.delegate.updateTable() {
                    self.delegate.notesTableView.setSelected(note: nUnwrapped)
                    UserDataService.instance.focusOnImport = nil
                }
            }
            return
        }
        
        guard storage.getProjectByNote(url: url) != nil else {
            return
        }
        
        guard let note = storage.initNote(url: url) else { return }
        note.load()
        note.loadModifiedLocalAt()
        
        print("FSWatcher import note: \"\(note.name)\"")
        self.storage.add(note)
        
        DispatchQueue.main.async {
            if let url = UserDataService.instance.focusOnImport,
               let note = self.storage.getBy(url: url)
            {
                self.delegate.updateTable() {
                    self.delegate.notesTableView.setSelected(note: note)
                    UserDataService.instance.focusOnImport = nil
                }
            } else {
                if !note.isTrash() {
                    self.delegate.notesTableView.insertNew(note: note)
                }
            }
        }
    }
    
    private func renameNote(note: Note) {
        if note.url == UserDataService.instance.focusOnImport {
            self.delegate.updateTable() {
                self.delegate.notesTableView.setSelected(note: note)
                UserDataService.instance.focusOnImport = nil
            }
            
        // On TextBundle import
        } else {
            self.reloadNote(note: note)
        }
    }
    
    private func removeNote(note: Note) {
        print("FSWatcher remove note: \"\(note.name)\"")
        
        self.storage.removeNotes(notes: [note], fsRemove: false) { _ in
            DispatchQueue.main.async {
                if self.delegate.notesTableView.numberOfRows > 0 {
                    self.delegate.notesTableView.removeByNotes(notes: [note])
                }
            }
        }
    }
    
    private func reloadNote(note: Note) {
        guard note.container != .encryptedTextPack else { return }
        guard let fsContent = note.getContent() else { return }
        
        let memoryContent = note.content.attributedSubstring(from: NSRange(0..<note.content.length))
        
        if (
            note.isRTF() && fsContent != memoryContent)
            || (
                !note.isRTF() && fsContent.string != memoryContent.string
            )
        {
            note.content = NSMutableAttributedString(attributedString: fsContent)

            // tags changes

            let result = note.scanContentTags()
            if result.0.count > 0 {
                DispatchQueue.main.async {
                    self.delegate.sidebarOutlineView.insertTags(note: note)
                }
            }

            if result.1.count > 0 {
                DispatchQueue.main.async {
                    self.delegate.sidebarOutlineView.removeTags(result.1)
                }
            }

            // reload view

            self.delegate.notesTableView.reloadRow(note: note)

            if EditTextView.note == note {
                DispatchQueue.main.async {
                    self.delegate.refillEditArea(force: true)
                }
            }
        }
    }
    
    private func handleTextBundle(url: URL) -> URL {
        if ["text.markdown", "text.md", "text.txt", "text.rtf"].contains(url.lastPathComponent) && url.path.contains(".textbundle") {
            let path = url.deletingLastPathComponent().path
            return URL(fileURLWithPath: path, isDirectory: false)
        }
        
        return url
    }
    
    public func restart() {
        watcher?.stop()
        self.observedFolders = self.storage.getProjectPaths()
        start()
    }

    public func reloadObservedFolders() {
        self.observedFolders = self.storage.getProjectPaths()
    }
}
