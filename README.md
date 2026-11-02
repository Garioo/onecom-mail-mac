# one.com Mail for Mac

A personal, unofficial Mac app for your one.com email. It has a **native mail client** that connects straight to one.com's mail servers. It also keeps one.com Webmail and the Control Panel one click away.

## Download and install

1. Download **one.com-Mail-….dmg** from the [latest release](https://github.com/Garioo/onecom-mail-mac/releases/latest).
2. Open it and drag **one.com Mail** onto **Applications**.
3. Open the app from Applications. The first time, macOS says it can't check the app for malicious software, because it isn't sold through Apple. Click **Done**, then open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to *one.com Mail*. You only do this once.
4. Sign in with your one.com email address and its password. Allow notifications when macOS asks.

Works on Apple silicon and Intel Macs with macOS 12 Monterey or later (Launch at Login needs macOS 13 Ventura or later).

## Updates

The app checks for new versions by itself every few hours. When there is one, a window shows what's new: click **Install Update** and it restarts with the new version. You can also choose *one.com Mail → Check for Updates…*.

## For the developer

Building from source needs the Xcode Command Line Tools (`xcode-select --install`).

- `bash build.sh` builds **one.com Mail Dev** from this folder (amber DEV icon, its own settings, notifications off at first), installs it in Applications next to one.com Mail and opens it. It updates itself whenever the source files here change, committed or not: an **Install Update** button appears at the bottom of the sidebar. It never checks GitHub and is never released.
- `bash release.sh 1.3 "What's new"` publishes a version on GitHub for everyone else. Commit your changes first. It builds for Intel and Apple silicon, makes the .dmg and the update file, signs the update and updates `appcast.xml`, the feed the app checks.
- Updates are signed with a private key kept in this Mac's Keychain (made once with `vendor/Sparkle/bin/generate_keys`). Back it up with `vendor/Sparkle/bin/generate_keys -x sparkle-key.txt` and keep that file somewhere safe and private: without the key, no further updates can be published.

## The mail screen

- **Sidebar** on the left, like Apple Mail: *Mailboxes* (Inbox with its unread count, Drafts, Sent, Archive, Junk, Trash), your own *Folders*, and *one.com* (Webmail, Control Panel). **New Folder** at the bottom of the sidebar (or *File → New Folder…*, ⌥⌘N, or right-click the sidebar) makes a folder on one.com. Right-click one of your own folders to **Rename** or **Delete** it (also under *File* for the open folder). Deleting asks first and says how many emails go with it; Inbox, Sent, Drafts, Archive, Junk and Trash can't be renamed or deleted. Your address and the **Install Update** button sit at the bottom too.
- **Toolbar** across the top: the mailbox name and unread count, then **Clean Up**, New Message, Reply, Reply All, Forward, Archive, Delete, Flag and Search. Right-click the toolbar to customise it (Get Mail and Read/Unread can be added).
- **Message list**: sender, time, subject and a two-line preview, with a grey monogram like Contacts. Unread mail has a blue dot. Paperclip, flag and replied icons show at a glance. Drag the line between the list and the reader to resize. **Drag messages onto a folder in the sidebar to move them** (drag a selection to move several), or right-click → *Move To*.
- **Reading pane**: subject, sender, recipients and date. Attachments appear as chips (click to save to Downloads and open).
- **Text size**: ⌘+ and ⌘− make the list and reader bigger or smaller (⌘0 for standard). On Webmail and Control Panel they zoom the page.
- **Dark mode**: emails designed on white are darkened to match the app, with photos kept in their real colours. Turn it off under *View → Darken Emails in Dark Mode*.
- **Privacy**: images from the web are blocked until you click *Load Images*. Scripts in emails never run.
- **Compose** opens in its own window: To / Cc / Bcc, Subject and a **rich-text** message. Send, Attach and Save Draft are in its toolbar; you can also drop files onto the window. ⌘↩ sends. Sent mail is saved to your Sent folder.
  - Formatting bar: bold, italic, underline, strikethrough, smaller/bigger text, bullets, links, fonts and text colour (also in the *Format* menu: ⌘B, ⌘I, ⌘U, ⌘K, ⌘T, ⇧⌘C)
  - Mail goes out as HTML with a plain-text version alongside, so it reads well everywhere. Quoted text in replies becomes a proper quote block.
- **Drafts**: ⌘S or *Save Draft* saves to your Drafts folder, and it also autosaves every 30 seconds. The compose window's title bar says when it was last saved. Closing an unsent message asks *Save / Don't Save / Cancel*. Open a draft in the Drafts folder and click **Edit Draft** (⌘E) to carry on; sending it removes the draft.
- **Mass delete**
  - *Multi-select*: ⌘-click or ⇧-click messages (⌘A for all). The reading pane turns into big buttons: Mark as Read/Unread, Flag, Archive, Delete. ⌫ deletes the whole selection. Right-click → *Select All Loaded from …* picks everything from one sender.
  - *Clean Up* (in the toolbar, ⇧⌘K): reads the whole folder and groups it by sender, biggest first, with counts, sizes, a bar showing each sender's share and a Newsletter tag. The button tells you exactly how many emails will go. Narrow it with *Older than…*, *Newsletters only* and *Read only*, tick senders, and move everything shown to Trash in one go. Right-click a message → *Clean Up Mail from …* opens it with that sender ticked. In Trash it deletes permanently (with a confirmation).
- **Calm design**: date headings (Today, Yesterday, Previous 7 Days, months), lighter type for read mail, and plain-text emails set in a comfortable reading column.
- **Search the whole server**: type in the search field (or press Return). Loaded messages filter instantly, then the server is searched. Choose *All Mail* (every folder except Trash and Junk) or just the current folder; results show which folder they're in.
- Native macOS look throughout. Follows light and dark mode.

## Also in the app

- **Webmail and Control Panel** in the sidebar: one.com's own web pages, for anything the native client doesn't do yet
- **New-mail notifications** with the sender and subject (checks every minute). Toggle under *one.com Mail → Notify on New Mail*
- **Unread count** on the Dock icon, in the menu bar and in the sidebar
- **Menu bar icon** with Open Mail, New Message, Control Panel and the settings
- **Launch at Login**, and **Sign Out of Mail…** under the app menu

## Shortcuts

| | |
|---|---|
| New message | ⌘N |
| Get new mail | ⇧⌘N |
| Reply / Reply All / Forward | ⌘R / ⇧⌘R / ⇧⌘F |
| Delete | ⌫ or ⌘⌫ |
| Mark read/unread · Flag · Archive | ⇧⌘U · ⇧⌘L · ⌃⌘A |
| Send (in compose) | ⌘↩ |
| Mail / Webmail / Control Panel | ⌘1 / ⌘2 / ⌘3 |
| New folder | ⌥⌘N |
| Bigger / smaller / standard text | ⌘+ / ⌘− / ⌘0 |
| Attach files (in compose) | ⇧⌘A |
| Reload web page | ⌥⌘R |

## Not yet

- Multiple accounts
- Pasting images into the message body (attach them instead)

## Servers

The defaults are one.com's: IMAP `imap.one.com:993` and SMTP `send.one.com:465`, both SSL/TLS. You can change them under *Server settings* on the sign-in screen. Your password is stored in the macOS Keychain and only sent to those servers.

## Files

- `OneMail.swift` — app window, sidebar, toolbar, menus, notifications, web views
- `Updater.swift` — notices new source files and rebuilds/relaunches the app
- `RichText.swift` — the rich-text editor and its HTML/plain-text conversion
- `MailViews.swift` — the mail screens (sign-in, list, reader, compose)
- `MailStore.swift` — mail state and actions, Keychain, new-mail checks
- `MailIMAP.swift` — IMAP (reading) and SMTP (sending) over TLS
- `MailMIME.swift` — email parsing (MIME, encodings, attachments) and building outgoing mail
- `AppIcon.swift` — draws the icon at build time
- `build.sh` — compiles, makes the icon, bundles Sparkle and signs the .app
- `DevBadge.swift` — adds the DEV band to the developer build's icon
- `release.sh` — publishes a version on GitHub (.dmg, signed update, `appcast.xml`)
