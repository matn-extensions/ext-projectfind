module matn.ui.shell.projectfind;

import std.algorithm : max, min, clamp, canFind, startsWith, endsWith, sort;
import std.conv : to;
import std.file : exists, isDir, dirEntries, SpanMode, isFile, readText, getSize, getcwd;
import std.path : baseName, dirName;
import std.process : execute;
import std.regex : regex, matchFirst, Regex;
import std.string : toLower, splitLines, strip, stripLeft, indexOf;

import matn.platform.sdl;
import matn.ui.grid.cell;
import matn.ui.grid.grid;
import matn.extension.base;

/// Returns visual column width of a UTF-8 string (counting code points)
private int btnW(string s) pure nothrow @nogc
{
    int count = 0;
    foreach (ubyte b; cast(const(ubyte)[]) s)
    {
        if ((b & 0xC0) != 0x80)
            count++;
    }
    return count;
}

private string getFileIcon(string filename)
{
    string lower = filename.toLower;
    string bName = lower;
    foreach_reverse (idx, char c; lower)
    {
        if (c == '/' || c == '\\')
        {
            bName = lower[idx + 1 .. $];
            break;
        }
    }

    if (bName == "androidmanifest.xml") return "";
    if (bName == "gradlew" || bName == "gradlew.bat") return "";
    if (bName == "build.gradle" || bName == "settings.gradle") return "";
    if (lower.length >= 2 && lower[$ - 2 .. $] == ".d") return "";
    if (lower.length >= 5 && lower[$ - 5 .. $] == ".json") return "";
    if (lower.length >= 3 && lower[$ - 3 .. $] == ".md") return "";
    if (lower.length >= 5 && lower[$ - 5 .. $] == ".toml") return "";
    if (lower.length >= 5 && lower[$ - 5 .. $] == ".yaml") return "";
    if (lower.length >= 4 && lower[$ - 4 .. $] == ".yml") return "";
    if (lower.length >= 3 && lower[$ - 3 .. $] == ".sh") return "";
    if (lower.length >= 5 && lower[$ - 5 .. $] == ".bash") return "";
    if (lower.length >= 2 && lower[$ - 2 .. $] == ".c") return "󰙲";
    if (lower.length >= 4 && lower[$ - 4 .. $] == ".cpp") return "󰙲";
    if (lower.length >= 2 && lower[$ - 2 .. $] == ".h") return "󰙲";
    if (lower.length >= 3 && lower[$ - 3 .. $] == ".py") return "";
    if (lower.length >= 3 && lower[$ - 3 .. $] == ".rs") return "";
    if (lower.length >= 3 && lower[$ - 3 .. $] == ".go") return "";
    if (lower.length >= 3 && lower[$ - 3 .. $] == ".js") return "";
    if (lower.length >= 3 && lower[$ - 3 .. $] == ".ts") return "";
    if (lower.length >= 5 && lower[$ - 5 .. $] == ".java") return "";
    if (lower.length >= 3 && lower[$ - 3 .. $] == ".kt" || (lower.length >= 4 && lower[$ - 4 .. $] == ".kts")) return "";
    if (lower.length >= 4 && lower[$ - 4 .. $] == ".xml" || (lower.length >= 5 && lower[$ - 5 .. $] == ".axml")) return "";
    if (lower.length >= 7 && lower[$ - 7 .. $] == ".gradle") return "";
    if (lower.length >= 11 && lower[$ - 11 .. $] == ".properties") return "";
    if (lower.length >= 4 && lower[$ - 4 .. $] == ".pro") return "󰒥";
    return "󰈙";
}

enum TreeRowKind
{
    dirNode,
    fileNode,
    matchItem
}

struct FlatTreeRow
{
    TreeRowKind kind;
    int depth;
    string pathKey;
    string label;
    int count;
    bool isExpanded;
    ProjectFindMatch match;
}

/// A single matched line in project search
struct ProjectFindMatch
{
    string filePath;
    string relativePath;
    int line;        // 0-indexed for editor cursor
    int displayLine; // 1-indexed for UI display
    int col;         // 0-indexed
    string lineContent;
    int matchStart;  // character index within stripped lineContent
    int matchLen;
}

/// Rendering and styling context passed to ProjectFindExtension
struct ProjectFindContext
{
    int gridCols;
    int gridRows;
    Color bg;
    Color barBg;
    Color text;
    Color muted;
    Color accent;
    Color border;
    Color activeLine;
    string projectRoot;
    bool isLight = false;
    bool showIcons = true;
    bool blink = true;
}

/// Find in Project interactive modal dialog
class ProjectFindExtension : Extension
{
    bool visible = false;
    string query = "";
    bool matchCase = false;
    bool useRegex = false;
    string activeRoot = "";

    bool isReferencesMode = false;
    string referencesSymbol = "";
    string referencesSourceLabel = "";
    ProjectFindMatch[] allReferences;

    ProjectFindMatch[] matches;
    FlatTreeRow[] treeRows;
    bool[string] collapsedDirs;
    bool[string] collapsedFiles;

    int selectedIndex = 0;
    int scrollOffset = 0;
    int hoveredIndex = -1;

    // Layout geometry for hit-testing
    int modalX;
    int modalY;
    int modalW;
    int modalH;
    int contentStartY;
    int visibleRowsCount;

    struct ClickableButton
    {
        int id; // 1=close, 2=case, 3=regex, 4=openFolder
        int row;
        int leftCol;
        int rightCol;
    }
    private ClickableButton[] clickButtons;

    struct ClickableRow
    {
        int treeRowIndex;
        int row;
        int leftCol;
        int rightCol;
    }
    private ClickableRow[] clickRows;

    // Jump callback: path, line (0-indexed), col (0-indexed)
    void delegate(string path, int line, int col) onJumpToLocation;
    void delegate() onOpenFolderPrompt;

    this()
    {
        super(ExtensionManifest(
            "matn.projectfind",
            "Find in Project",
            "1.0.0",
            "Matn Core",
            "Live multi-threaded workspace text search across files with ripgrep",
            true
        ));
    }

    override void onProjectOpened(string rootPath)
    {
        activeRoot = rootPath;
        if (visible && query.length >= 2)
            performSearch();
    }

    override void onProjectClosed()
    {
        activeRoot = "";
        matches = [];
        treeRows = [];
        collapsedDirs = null;
        collapsedFiles = null;
        selectedIndex = 0;
        scrollOffset = 0;
    }

    override protected void onActivate()
    {
        if (_context)
        {
            _context.registerCommand(ExtensionCommand(
                "project.find",
                "Find in Project",
                "Search",
                "Ctrl+Shift+F",
                { open(); }
            ));
        }
    }

    void open(string rootDir = "")
    {
        isReferencesMode = false;
        referencesSymbol = "";
        referencesSourceLabel = "";
        allReferences = [];

        visible = true;
        if (rootDir.length > 0 && exists(rootDir) && isDir(rootDir))
            activeRoot = rootDir;
        else if (_context && _context.hasProject())
            activeRoot = _context.projectRoot();
        else
            activeRoot = "";

        collapsedDirs = null;
        collapsedFiles = null;
        selectedIndex = 0;
        scrollOffset = 0;
        hoveredIndex = -1;
        if (activeRoot.length > 0 && query.length >= 2)
            performSearch();
        else
        {
            matches = [];
            rebuildTree();
        }
    }

    void setCustomMatches(string queryText, ProjectFindMatch[] customMatches)
    {
        isReferencesMode = false;
        referencesSymbol = "";
        referencesSourceLabel = "";
        allReferences = [];

        collapsedDirs = null;
        collapsedFiles = null;
        query = queryText;
        matches = customMatches;
        selectedIndex = 0;
        scrollOffset = 0;
        hoveredIndex = -1;
        visible = true;
        if (_context && _context.hasProject())
            activeRoot = _context.projectRoot();
        rebuildTree();
    }

    void setReferencesMatches(string symbol, ProjectFindMatch[] customMatches, string sourceLabel = "Semantic References")
    {
        isReferencesMode = true;
        referencesSymbol = symbol;
        referencesSourceLabel = sourceLabel;
        allReferences = customMatches;
        matches = customMatches;
        collapsedDirs = null;
        collapsedFiles = null;
        query = "";
        selectedIndex = 0;
        scrollOffset = 0;
        hoveredIndex = -1;
        visible = true;
        if (_context && _context.hasProject())
            activeRoot = _context.projectRoot();
        rebuildTree();
    }

    private void filterReferences()
    {
        if (query.length == 0)
        {
            matches = allReferences;
        }
        else
        {
            string qLower = query.toLower();
            ProjectFindMatch[] filtered;
            foreach (ref m; allReferences)
            {
                if (m.relativePath.toLower().canFind(qLower) || m.lineContent.toLower().canFind(qLower))
                {
                    filtered ~= m;
                }
            }
            matches = filtered;
        }
        selectedIndex = 0;
        scrollOffset = 0;
        hoveredIndex = -1;
        rebuildTree();
    }

    void openWithQuery(string q, string rootDir = "")
    {
        query = q;
        open(rootDir);
    }

    void close()
    {
        visible = false;
        isReferencesMode = false;
        referencesSymbol = "";
        referencesSourceLabel = "";
        allReferences = [];
    }

    void toggle(string rootDir = "")
    {
        if (visible)
            close();
        else
            open(rootDir);
    }

    void rebuildTree()
    {
        struct TempFile
        {
            string filePath;
            string relPath;
            string fileName;
            ProjectFindMatch[] matches;
        }

        struct TempDir
        {
            string dirPath;
            TempFile[string] files;
            int totalMatches;
        }

        TempDir[string] dirMap;

        foreach (ref m; matches)
        {
            string rel = m.relativePath;
            string d = dirName(rel);
            if (d == "." || d.length == 0)
                d = "[root]";
            string f = baseName(rel);

            if (d !in dirMap)
                dirMap[d] = TempDir(d);

            auto dirPtr = &dirMap[d];
            dirPtr.totalMatches++;

            if (m.filePath !in dirPtr.files)
                dirPtr.files[m.filePath] = TempFile(m.filePath, rel, f);

            auto filePtr = &dirPtr.files[m.filePath];
            filePtr.matches ~= m;
        }

        string[] sortedDirs = dirMap.keys;
        sort!((a, b) {
            if (a == "[root]") return true;
            if (b == "[root]") return false;
            return a < b;
        })(sortedDirs);

        treeRows = [];

        foreach (dName; sortedDirs)
        {
            auto d = dirMap[dName];
            bool isDirCollapsed = (d.dirPath in collapsedDirs) !is null;
            bool showDirHeader = (d.dirPath != "[root]" || sortedDirs.length > 1);

            if (showDirHeader)
            {
                treeRows ~= FlatTreeRow(
                    TreeRowKind.dirNode,
                    0,
                    d.dirPath,
                    d.dirPath,
                    d.totalMatches,
                    !isDirCollapsed,
                    ProjectFindMatch.init
                );
            }

            if (!showDirHeader || !isDirCollapsed)
            {
                int fileDepth = showDirHeader ? 1 : 0;
                string[] sortedFileKeys = d.files.keys;
                sort!((a, b) => d.files[a].fileName < d.files[b].fileName)(sortedFileKeys);

                foreach (fKey; sortedFileKeys)
                {
                    auto f = d.files[fKey];
                    bool isFileCollapsed = (f.filePath in collapsedFiles) !is null;

                    treeRows ~= FlatTreeRow(
                        TreeRowKind.fileNode,
                        fileDepth,
                        f.filePath,
                        f.fileName,
                        cast(int) f.matches.length,
                        !isFileCollapsed,
                        ProjectFindMatch.init
                    );

                    if (!isFileCollapsed)
                    {
                        int itemDepth = fileDepth + 1;
                        sort!((a, b) {
                            if (a.line != b.line) return a.line < b.line;
                            return a.col < b.col;
                        })(f.matches);

                        foreach (ref match; f.matches)
                        {
                            treeRows ~= FlatTreeRow(
                                TreeRowKind.matchItem,
                                itemDepth,
                                f.filePath,
                                "",
                                1,
                                true,
                                match
                            );
                        }
                    }
                }
            }
        }

        selectedIndex = clamp(selectedIndex, 0, max(0, cast(int) treeRows.length - 1));
        ensureVisible(selectedIndex);
    }

    void ensureVisible(int itemIdx)
    {
        if (visibleRowsCount <= 0) return;
        if (itemIdx < scrollOffset)
            scrollOffset = itemIdx;
        else if (itemIdx >= scrollOffset + visibleRowsCount)
            scrollOffset = itemIdx - visibleRowsCount + 1;
        scrollOffset = clamp(scrollOffset, 0, max(0, cast(int) treeRows.length - visibleRowsCount));
    }

    void moveSelection(int delta)
    {
        if (treeRows.length == 0) return;
        selectedIndex = clamp(selectedIndex + delta, 0, cast(int) treeRows.length - 1);
        ensureVisible(selectedIndex);
    }

    void applySelected()
    {
        if (selectedIndex >= 0 && selectedIndex < treeRows.length)
        {
            auto r = treeRows[selectedIndex];
            if (r.kind == TreeRowKind.dirNode)
            {
                if (r.pathKey in collapsedDirs)
                    collapsedDirs.remove(r.pathKey);
                else
                    collapsedDirs[r.pathKey] = true;
                rebuildTree();
                return;
            }
            else if (r.kind == TreeRowKind.fileNode)
            {
                if (r.pathKey in collapsedFiles)
                    collapsedFiles.remove(r.pathKey);
                else
                    collapsedFiles[r.pathKey] = true;
                rebuildTree();
                return;
            }
            else if (r.kind == TreeRowKind.matchItem)
            {
                close();
                if (onJumpToLocation)
                    onJumpToLocation(r.match.filePath, r.match.line, r.match.col);
                else if (_context)
                    _context.openFileAt(r.match.filePath, r.match.line, r.match.col);
                return;
            }
        }

        if (activeRoot.length == 0)
        {
            close();
            if (onOpenFolderPrompt)
                onOpenFolderPrompt();
            else if (_context)
                _context.openFolderPrompt();
            return;
        }
    }

    void performSearch()
    {
        matches = [];
        selectedIndex = 0;
        scrollOffset = 0;
        if (query.length < 2)
        {
            rebuildTree();
            return;
        }

        string root = activeRoot;
        if (root.length == 0 || !exists(root) || !isDir(root))
        {
            if (_context && _context.hasProject())
                root = _context.projectRoot();
            else
                root = "";
        }

        if (root.length == 0 || !exists(root) || !isDir(root))
        {
            rebuildTree();
            return; // No project open, do not search
        }

        // 1. Primary engine: ripgrep
        string[] args = ["rg", "--line-number", "--column", "--no-heading", "--color=never",
                         "--max-filesize", "1M", "-m", "300"];
        if (!matchCase)
            args ~= "-i";
        if (!useRegex)
            args ~= "-F";
        args ~= ["-e", query, root];

        try
        {
            auto res = execute(args);
            if (res.status == 0 || res.status == 1)
            {
                parseRgOutput(res.output, root);
                return;
            }
        }
        catch (Exception)
        {
            // Fall back to built-in search
        }

        fallbackInternalSearch(root);
    }

    private void parseRgOutput(string output, string root)
    {
        matches = [];
        foreach (line; output.splitLines())
        {
            if (line.length == 0) continue;

            auto i1 = line.indexOf(':');
            if (i1 < 0) continue;
            auto i2 = line.indexOf(':', i1 + 1);
            if (i2 < 0) continue;
            auto i3 = line.indexOf(':', i2 + 1);
            if (i3 < 0) continue;

            string fullPath = line[0 .. i1];
            int lineNo = 1;
            int colNo = 1;
            try
            {
                lineNo = to!int(line[i1 + 1 .. i2]);
                colNo = to!int(line[i2 + 1 .. i3]);
            }
            catch (Exception)
            {
                continue;
            }

            string content = line[i3 + 1 .. $];

            string relPath = fullPath;
            if (root.length > 0 && fullPath.startsWith(root))
            {
                relPath = fullPath[root.length .. $];
                if (relPath.startsWith("/") || relPath.startsWith("\\"))
                    relPath = relPath[1 .. $];
            }

            string stripped = content.stripLeft();
            int matchStart = -1;
            int matchLen = cast(int) query.length;

            if (useRegex)
            {
                try
                {
                    auto re = regex(query, matchCase ? "" : "i");
                    auto m = matchFirst(stripped, re);
                    if (!m.empty)
                    {
                        matchStart = cast(int) m.pre.length;
                        matchLen = cast(int) m[0].length;
                    }
                }
                catch (Exception) {}
            }
            else
            {
                string hay = matchCase ? stripped : stripped.toLower();
                string needle = matchCase ? query : query.toLower();
                auto idx = hay.indexOf(needle);
                if (idx >= 0)
                {
                    matchStart = cast(int) idx;
                    matchLen = cast(int) query.length;
                }
            }

            matches ~= ProjectFindMatch(
                fullPath,
                relPath,
                max(0, lineNo - 1),
                lineNo,
                max(0, colNo - 1),
                stripped,
                matchStart,
                matchLen
            );

            if (matches.length >= 300) break;
        }
        rebuildTree();
    }

    private void fallbackInternalSearch(string root)
    {
        matches = [];
        if (!exists(root)) return;

        try
        {
            foreach (entry; dirEntries(root, SpanMode.depth))
            {
                if (matches.length >= 300) break;
                if (!entry.isFile) continue;

                string p = entry.name;
                if (p.canFind("/.") || p.canFind("/build/") || p.canFind("/node_modules/"))
                    continue;
                if (entry.size > 1_000_000) continue;

                string text;
                try { text = readText(entry.name); } catch (Exception) { continue; }

                int lineIdx = 0;
                foreach (line; text.splitLines())
                {
                    if (matches.length >= 300) break;

                    string stripped = line.stripLeft();
                    int matchStart = -1;
                    int matchLen = cast(int) query.length;

                    if (useRegex)
                    {
                        try
                        {
                            auto re = regex(query, matchCase ? "" : "i");
                            auto m = matchFirst(stripped, re);
                            if (!m.empty)
                            {
                                matchStart = cast(int) m.pre.length;
                                matchLen = cast(int) m[0].length;
                            }
                        }
                        catch (Exception) {}
                    }
                    else
                    {
                        string hay = matchCase ? stripped : stripped.toLower();
                        string needle = matchCase ? query : query.toLower();
                        auto idx = hay.indexOf(needle);
                        if (idx >= 0)
                        {
                            matchStart = cast(int) idx;
                            matchLen = cast(int) query.length;
                        }
                    }

                    if (matchStart >= 0)
                    {
                        string relPath = entry.name;
                        if (root.length > 0 && entry.name.startsWith(root))
                        {
                            relPath = entry.name[root.length .. $];
                            if (relPath.startsWith("/") || relPath.startsWith("\\"))
                                relPath = relPath[1 .. $];
                        }

                        matches ~= ProjectFindMatch(
                            entry.name,
                            relPath,
                            lineIdx,
                            lineIdx + 1,
                            matchStart,
                            stripped,
                            matchStart,
                            matchLen
                        );
                    }
                    lineIdx++;
                }
            }
        }
        catch (Exception) {}
        rebuildTree();
    }

    bool handleKeyDown(uint key, uint mod, ProjectFindContext ctx)
    {
        if (!visible) return false;

        bool isCtrl = (mod & SDL_KMOD_CTRL) != 0;
        bool isAlt = (mod & SDL_KMOD_ALT) != 0;
        bool isShift = (mod & SDL_KMOD_SHIFT) != 0;

        if (key == SDLK_ESCAPE)
        {
            close();
            return true;
        }
        else if (isCtrl && isShift && (key == 'f' || key == 'F'))
        {
            close();
            return true;
        }
        else if (isAlt && (key == 'c' || key == 'C'))
        {
            matchCase = !matchCase;
            performSearch();
            return true;
        }
        else if (isAlt && (key == 'r' || key == 'R'))
        {
            useRegex = !useRegex;
            performSearch();
            return true;
        }
        else if (key == SDLK_UP)
        {
            moveSelection(-1);
            return true;
        }
        else if (key == SDLK_DOWN)
        {
            moveSelection(1);
            return true;
        }
        else if (key == 0x4000004b) // PageUp
        {
            moveSelection(-5);
            return true;
        }
        else if (key == 0x4000004e) // PageDown
        {
            moveSelection(5);
            return true;
        }
        else if (key == 0x4000004a) // Home
        {
            selectedIndex = 0;
            ensureVisible(selectedIndex);
            return true;
        }
        else if (key == 0x4000004d) // End
        {
            if (treeRows.length > 0)
                selectedIndex = cast(int) treeRows.length - 1;
            ensureVisible(selectedIndex);
            return true;
        }
        else if (key == 0x40000050) // SDLK_LEFT
        {
            if (selectedIndex >= 0 && selectedIndex < treeRows.length)
            {
                auto r = treeRows[selectedIndex];
                if (r.kind == TreeRowKind.dirNode && r.isExpanded)
                {
                    collapsedDirs[r.pathKey] = true;
                    rebuildTree();
                }
                else if (r.kind == TreeRowKind.fileNode && r.isExpanded)
                {
                    collapsedFiles[r.pathKey] = true;
                    rebuildTree();
                }
                else
                {
                    moveSelection(-1);
                }
            }
            return true;
        }
        else if (key == 0x4000004f) // SDLK_RIGHT
        {
            if (selectedIndex >= 0 && selectedIndex < treeRows.length)
            {
                auto r = treeRows[selectedIndex];
                if (r.kind == TreeRowKind.dirNode && !r.isExpanded)
                {
                    collapsedDirs.remove(r.pathKey);
                    rebuildTree();
                }
                else if (r.kind == TreeRowKind.fileNode && !r.isExpanded)
                {
                    collapsedFiles.remove(r.pathKey);
                    rebuildTree();
                }
                else
                {
                    moveSelection(1);
                }
            }
            return true;
        }
        else if (key == SDLK_RETURN || key == 0x40000058)
        {
            applySelected();
            return true;
        }
        else if (key == SDLK_BACKSPACE || key == 0x8)
        {
            if (query.length > 0)
            {
                query = query[0 .. $ - 1];
                if (isReferencesMode)
                    filterReferences();
                else
                    performSearch();
            }
            return true;
        }

        return false;
    }

    bool handleTextInput(string text)
    {
        if (!visible || text.length == 0) return false;
        query ~= text;
        if (isReferencesMode)
            filterReferences();
        else
            performSearch();
        return true;
    }

    bool handleMouseMove(int col, int row)
    {
        if (!visible) return false;
        int oldHover = hoveredIndex;
        hoveredIndex = -1;

        foreach (ref cr; clickRows)
        {
            if (row == cr.row && col >= cr.leftCol && col < cr.rightCol)
            {
                hoveredIndex = cr.treeRowIndex;
                break;
            }
        }
        return (oldHover != hoveredIndex);
    }

    bool handleMouseDown(int col, int row, ProjectFindContext ctx)
    {
        if (!visible) return false;

        // Click outside closes modal
        if (col < modalX || col >= modalX + modalW || row < modalY || row >= modalY + modalH)
        {
            close();
            return true;
        }

        // Header buttons (Close [x], Case [Aa], Regex [.*])
        foreach (ref cb; clickButtons)
        {
            if (row == cb.row && col >= cb.leftCol && col < cb.rightCol)
            {
                switch (cb.id)
                {
                case 1: // Close
                    close();
                    return true;
                case 2: // Toggle Case
                    matchCase = !matchCase;
                    performSearch();
                    return true;
                case 3: // Toggle Regex
                    useRegex = !useRegex;
                    performSearch();
                    return true;
                case 4: // Open Folder
                    close();
                    if (onOpenFolderPrompt)
                        onOpenFolderPrompt();
                    else if (_context)
                        _context.openFolderPrompt();
                    return true;
                default:
                    break;
                }
            }
        }

        // Click on match / tree row
        foreach (ref cr; clickRows)
        {
            if (row == cr.row && col >= cr.leftCol && col < cr.rightCol)
            {
                if (cr.treeRowIndex >= 0 && cr.treeRowIndex < treeRows.length)
                {
                    selectedIndex = cr.treeRowIndex;
                    auto r = treeRows[cr.treeRowIndex];
                    if (r.kind == TreeRowKind.dirNode)
                    {
                        if (r.pathKey in collapsedDirs)
                            collapsedDirs.remove(r.pathKey);
                        else
                            collapsedDirs[r.pathKey] = true;
                        rebuildTree();
                        return true;
                    }
                    else if (r.kind == TreeRowKind.fileNode)
                    {
                        if (r.pathKey in collapsedFiles)
                            collapsedFiles.remove(r.pathKey);
                        else
                            collapsedFiles[r.pathKey] = true;
                        rebuildTree();
                        return true;
                    }
                    else if (r.kind == TreeRowKind.matchItem)
                    {
                        close();
                        if (onJumpToLocation)
                            onJumpToLocation(r.match.filePath, r.match.line, r.match.col);
                        else if (_context)
                            _context.openFileAt(r.match.filePath, r.match.line, r.match.col);
                        return true;
                    }
                }
                return true;
            }
        }

        return true;
    }

    bool handleMouseWheel(int wheelY)
    {
        if (!visible) return false;
        if (wheelY > 0)
            moveSelection(-2);
        else if (wheelY < 0)
            moveSelection(2);
        return true;
    }

    void render(GlyphGrid grid, ProjectFindContext ctx)
    {
        if (!visible) return;

        clickButtons = [];
        clickRows = [];

        modalW = min(88, max(56, ctx.gridCols - 4));
        modalH = min(26, max(18, ctx.gridRows - 2));
        modalX = max(0, (ctx.gridCols - modalW) / 2);
        modalY = max(0, (ctx.gridRows - modalH) / 2);

        bool isLight = ctx.isLight || ctx.bg.isLight;
        Color modalBg = ctx.barBg;
        Color headerBg = isLight ? ctx.barBg.darken(6) : ctx.barBg.lighten(6);
        Color searchBg = ctx.bg;
        Color selRowBg = ctx.activeLine;
        Color hoverRowBg = ctx.activeLine.blend(ctx.barBg, 0.45f);
        Color btnBg = ctx.activeLine;

        // 1. Fill entire modal background
        grid.fillRect(modalX, modalY, modalW, modalH, ' ', CellStyle(ctx.text, modalBg));

        // 2. Header Bar (Row modalY)
        grid.fillRect(modalX, modalY, modalW, 1, ' ', CellStyle(ctx.text, modalBg));

        int closeCol = modalX + modalW - 3;

        if (isReferencesMode)
        {
            string title = "REFERENCES: " ~ referencesSymbol;
            grid.putString(modalX + 2, modalY, to!dstring(title), CellStyle(ctx.accent, modalBg, CellAttr.bold));

            int titleW = cast(int) title.length + 3;
            if (referencesSourceLabel.length > 0)
            {
                string badge = "[" ~ referencesSourceLabel ~ "]";
                int maxBadgeW = max(0, (closeCol - 2) - (modalX + titleW));
                if (maxBadgeW > 4)
                {
                    grid.putString(modalX + titleW, modalY, to!dstring(badge), CellStyle(ctx.accent, modalBg, CellAttr.bold), maxBadgeW);
                }
            }
        }
        else
        {
            string title = "FIND IN PROJECT";
            grid.putString(modalX + 2, modalY, to!dstring(title), CellStyle(ctx.muted, modalBg, CellAttr.bold));

            // Workspace breadcrumb
            int titleW = cast(int) title.length + 3;
            int maxPathW = max(0, (closeCol - 2) - (modalX + titleW));
            if (maxPathW > 6)
            {
                string wsStr;
                if (activeRoot.length > 0)
                    wsStr = "Workspace: " ~ baseName(activeRoot);
                else
                    wsStr = "Workspace: (No project open)";
                grid.putString(modalX + titleW, modalY, to!dstring(wsStr), CellStyle(ctx.muted, modalBg));
            }
        }

        // Close button [x] at top right without gaps
        grid.putString(closeCol, modalY, "[x]"d, CellStyle(ctx.muted, modalBg));
        clickButtons ~= ClickableButton(1, modalY, closeCol, modalX + modalW);

        // 3. Search Bar (Row modalY + 1)
        int searchY = modalY + 1;
        grid.fillRect(modalX, searchY, modalW, 1, ' ', CellStyle(ctx.text, searchBg));
        grid.putString(modalX + 2, searchY, isReferencesMode ? "󰈢 " : " ", CellStyle(ctx.muted, searchBg));

        // Right side toggle buttons: [ Aa ][ .* ] (flush adjacent, zero gap, only for search mode)
        int curBtnRight = modalX + modalW - 1;

        if (!isReferencesMode)
        {
            // Regex toggle button: [ .* ]
            string regexBtn = " .* ";
            int regexW = btnW(regexBtn);
            int regexCol = curBtnRight - regexW;
            Color regexFg = useRegex ? Color.black : ctx.muted;
            Color regexBg = useRegex ? ctx.accent : btnBg;
            ubyte regexAttr = useRegex ? CellAttr.bold : CellAttr.none;
            grid.putString(regexCol, searchY, regexBtn, CellStyle(regexFg, regexBg, regexAttr));
            clickButtons ~= ClickableButton(3, searchY, regexCol, regexCol + regexW);
            curBtnRight = regexCol;

            // Case toggle button: [ Aa ]
            string caseBtn = " Aa ";
            int caseW = btnW(caseBtn);
            int caseCol = curBtnRight - caseW;
            Color caseFg = matchCase ? Color.black : ctx.muted;
            Color caseBg = matchCase ? ctx.accent : btnBg;
            ubyte caseAttr = matchCase ? CellAttr.bold : CellAttr.none;
            grid.putString(caseCol, searchY, caseBtn, CellStyle(caseFg, caseBg, caseAttr));
            clickButtons ~= ClickableButton(2, searchY, caseCol, caseCol + caseW);
            curBtnRight = caseCol;
        }

        // Search input text
        int inCol = modalX + 5;
        int maxInW = max(4, curBtnRight - inCol - 1);
        if (query.length > 0)
        {
            grid.putString(inCol, searchY, query, CellStyle(ctx.text, searchBg, CellAttr.bold), maxInW);
            int curPos = min(maxInW - 1, cast(int) query.length);
            int cursorCol = inCol + curPos;
            if (ctx.blink && cursorCol >= 0 && cursorCol < grid.cols && searchY >= 0 && searchY < grid.rows)
            {
                auto cell = &grid.cells[searchY * grid.cols + cursorCol];
                cell.style.attrs |= CellAttr.negative;
            }
        }
        else
        {
            string placeholder = isReferencesMode ?
                "Filter references by file or text..." :
                "Search text across all files in workspace...";
            grid.putString(inCol, searchY, placeholder, CellStyle(ctx.muted, searchBg, CellAttr.italic), maxInW);
            int cursorCol = inCol;
            if (ctx.blink && cursorCol >= 0 && cursorCol < grid.cols && searchY >= 0 && searchY < grid.rows)
            {
                auto cell = &grid.cells[searchY * grid.cols + cursorCol];
                cell.style.attrs |= CellAttr.negative;
            }
        }

        // 4. Status / Summary row (Row modalY + 2)
        int summaryY = modalY + 2;
        grid.fillRect(modalX, summaryY, modalW, 1, ' ', CellStyle(ctx.muted, headerBg));

        string summaryStr;
        if (isReferencesMode)
        {
            if (allReferences.length == 0)
            {
                summaryStr = " No references found for '" ~ referencesSymbol ~ "'";
            }
            else if (matches.length == 0)
            {
                summaryStr = " No references match filter '" ~ query ~ "' (0 of " ~ to!string(allReferences.length) ~ " total)";
            }
            else
            {
                summaryStr = " " ~ to!string(matches.length) ~ " of " ~ to!string(allReferences.length) ~
                             " references for '" ~ referencesSymbol ~ "'  •  Enter/Click to open, Left/Right to collapse";
            }
        }
        else
        {
            if (activeRoot.length == 0)
            {
                summaryStr = " No project open — open a folder to search project files";
            }
            else if (query.length < 2)
            {
                summaryStr = " Type at least 2 characters to search... (Alt+C: Case, Alt+R: Regex)";
            }
            else if (matches.length == 0)
            {
                summaryStr = " No matches found in project workspace";
            }
            else
            {
                summaryStr = " " ~ to!string(matches.length) ~ (matches.length >= 300 ? "+ matches" : " matches") ~
                             "  •  Enter/Click to open, Left/Right to collapse";
            }
        }
        grid.putString(modalX + 1, summaryY, to!dstring(summaryStr), CellStyle(ctx.muted, headerBg));

        // 5. Results List (Rows modalY + 3 .. modalY + modalH - 1)
        contentStartY = modalY + 3;
        visibleRowsCount = max(1, modalH - 3);

        if (activeRoot.length == 0 && !isReferencesMode)
        {
            int midY = contentStartY + max(1, visibleRowsCount / 3);
            string msg = "No project workspace is currently open.";
            int msgX = max(modalX + 2, modalX + (modalW - cast(int) msg.length) / 2);
            grid.putString(msgX, midY, to!dstring(msg), CellStyle(ctx.muted, modalBg));

            string btnText = "[ 󰉋 Open Folder ]";
            int bW = btnW(btnText);
            int btnX = max(modalX + 2, modalX + (modalW - bW) / 2);
            int btnY = midY + 2;
            grid.putString(btnX, btnY, to!dstring(btnText), CellStyle(Color.black, ctx.accent, CellAttr.bold));
            clickButtons ~= ClickableButton(4, btnY, btnX, btnX + bW);
            return;
        }

        if (matches.length == 0)
        {
            int midY = contentStartY + max(1, visibleRowsCount / 3);
            string msg = isReferencesMode ? "No references match the filter." : "No matches found in project workspace.";
            int msgX = max(modalX + 2, modalX + (modalW - cast(int) msg.length) / 2);
            grid.putString(msgX, midY, to!dstring(msg), CellStyle(ctx.muted, modalBg));
            return;
        }

        foreach (slot; 0 .. visibleRowsCount)
        {
            int itemIdx = scrollOffset + slot;
            int r = contentStartY + slot;

            if (itemIdx >= treeRows.length)
            {
                grid.fillRect(modalX + 1, r, modalW - 2, 1, ' ', CellStyle(ctx.text, modalBg));
                continue;
            }

            auto row = treeRows[itemIdx];
            bool isSelected = (itemIdx == selectedIndex);
            bool isHovered = (itemIdx == hoveredIndex);

            if (row.kind == TreeRowKind.dirNode)
            {
                Color dirBg = isSelected ? ctx.activeLine : (isHovered ? hoverRowBg : headerBg);
                grid.fillRect(modalX + 1, r, modalW - 2, 1, ' ', CellStyle(ctx.text, dirBg));

                int curX = modalX + 2;
                dstring expandIcon = row.isExpanded ? "▾ "d : "▸ "d;
                grid.putString(curX, r, expandIcon, CellStyle(ctx.accent, dirBg, CellAttr.bold));
                curX += cast(int) expandIcon.length;

                string folderIcon = ctx.showIcons ? "󰉓 " : "[D] ";
                grid.putString(curX, r, to!dstring(folderIcon), CellStyle(ctx.accent, dirBg, CellAttr.bold));
                curX += cast(int) folderIcon.length;

                grid.putString(curX, r, to!dstring(row.label), CellStyle(ctx.accent, dirBg, CellAttr.bold));
                curX += cast(int) row.label.length + 2;

                string countStr = to!string(row.count) ~ (row.count == 1 ? " match" : " matches");
                int dBadgeX = modalX + modalW - 2 - cast(int) countStr.length;
                if (dBadgeX > curX)
                    grid.putString(dBadgeX, r, to!dstring(countStr), CellStyle(ctx.muted, dirBg, CellAttr.bold));
            }
            else if (row.kind == TreeRowKind.fileNode)
            {
                Color fileBg = isSelected ? ctx.activeLine : (isHovered ? hoverRowBg : modalBg);
                grid.fillRect(modalX + 1, r, modalW - 2, 1, ' ', CellStyle(ctx.text, fileBg));

                int curX = modalX + 2 + row.depth * 2;
                dstring expandIcon = row.isExpanded ? "▾ "d : "▸ "d;
                grid.putString(curX, r, expandIcon, CellStyle(ctx.muted, fileBg));
                curX += cast(int) expandIcon.length;

                string fIcon = ctx.showIcons ? (getFileIcon(row.label) ~ " ") : "";
                if (fIcon.length > 0)
                {
                    grid.putString(curX, r, to!dstring(fIcon), CellStyle(ctx.accent, fileBg));
                    curX += cast(int) fIcon.length;
                }

                grid.putString(curX, r, to!dstring(row.label), CellStyle(ctx.text, fileBg, CellAttr.bold));
                curX += cast(int) row.label.length + 2;

                string countStr = to!string(row.count);
                int fBadgeX = modalX + modalW - 2 - cast(int) countStr.length;
                if (fBadgeX > curX)
                    grid.putString(fBadgeX, r, to!dstring(countStr), CellStyle(ctx.muted, fileBg));
            }
            else if (row.kind == TreeRowKind.matchItem)
            {
                auto m = row.match;
                Color rowBg = isSelected ? selRowBg : (isHovered ? hoverRowBg : modalBg);
                grid.fillRect(modalX + 1, r, modalW - 2, 1, ' ', CellStyle(ctx.text, rowBg));

                int curX = modalX + 2 + row.depth * 2;

                // Line number
                string lineStr = to!string(m.displayLine) ~ ":";
                int lineColW = max(5, cast(int) lineStr.length + 1);
                grid.putString(curX, r, to!dstring(lineStr), CellStyle(isSelected ? ctx.accent : ctx.muted, rowBg, CellAttr.bold));
                curX += lineColW;

                // Margin separator (clean space, no ASCII box characters)
                grid.putString(curX, r, " "d, CellStyle(ctx.border, rowBg));
                curX += 2;

                // Line Content Preview with Match Highlight
                int maxPreviewW = (modalX + modalW - 2) - curX;
                if (maxPreviewW > 4)
                {
                    dstring dline = to!dstring(m.lineContent);
                    int pX = curX;
                    bool inRoleTag = dline.startsWith("["d) && dline.canFind("]"d);
                    size_t tagEnd = inRoleTag ? dline.indexOf("]"d) : 0;

                    foreach (chIdx, dchar ch; dline)
                    {
                        if (pX >= modalX + modalW - 2) break;
                        bool isHighlight = (m.matchStart >= 0 && cast(int) chIdx >= m.matchStart && cast(int) chIdx < m.matchStart + m.matchLen);

                        Color fg;
                        Color bg = isHighlight ? ctx.accent : rowBg;
                        ubyte attr = isHighlight ? (CellAttr.bold | CellAttr.underline) : CellAttr.none;

                        if (isHighlight)
                        {
                            fg = Color.black;
                        }
                        else if (inRoleTag && chIdx <= tagEnd)
                        {
                            if (dline.startsWith("[decl]"))
                                fg = Color(100, 180, 255, 255);
                            else if (dline.startsWith("[call]"))
                                fg = Color(245, 175, 95, 255);
                            else if (dline.startsWith("[member]"))
                                fg = Color(180, 150, 230, 255);
                            else if (dline.startsWith("[write]"))
                                fg = Color(230, 110, 130, 255);
                            else
                                fg = Color(140, 190, 140, 255);
                            attr |= CellAttr.bold;
                        }
                        else
                        {
                            fg = isSelected ? Color.white : ctx.text;
                        }

                        grid.putCell(pX, r, ch, CellStyle(fg, bg, attr));
                        pX++;
                    }
                }
            }

            clickRows ~= ClickableRow(itemIdx, r, modalX + 1, modalX + modalW - 1);
        }
    }
}

unittest
{
    auto finder = new ProjectFindExtension();
    assert(!finder.visible);
    assert(finder.query == "");

    string sampleRg = "source/foo.d:42:10:    void openFile();\n" ~
                      "source/bar.d:105:5:int x = openFile();\n";
    finder.query = "openFile";
    finder.parseRgOutput(sampleRg, "");

    assert(finder.matches.length == 2);
    assert(finder.matches[0].filePath == "source/foo.d");
    assert(finder.matches[0].displayLine == 42);
    assert(finder.matches[0].line == 41);
    assert(finder.matches[0].col == 9);
    assert(finder.matches[0].lineContent == "void openFile();");
    assert(finder.matches[0].matchStart == 5);
    assert(finder.matches[0].matchLen == 8);

    assert(finder.matches[1].filePath == "source/bar.d");
    assert(finder.matches[1].displayLine == 105);
    assert(finder.matches[1].line == 104);

    assert(finder.treeRows.length == 5);
    assert(finder.treeRows[0].kind == TreeRowKind.dirNode);
    assert(finder.treeRows[0].label == "source");
    assert(finder.treeRows[0].count == 2);
    assert(finder.treeRows[1].kind == TreeRowKind.fileNode);
    assert(finder.treeRows[1].label == "bar.d");
    assert(finder.treeRows[1].count == 1);
    assert(finder.treeRows[2].kind == TreeRowKind.matchItem);
    assert(finder.treeRows[2].match.displayLine == 105);
    assert(finder.treeRows[3].kind == TreeRowKind.fileNode);
    assert(finder.treeRows[3].label == "foo.d");
    assert(finder.treeRows[3].count == 1);
    assert(finder.treeRows[4].kind == TreeRowKind.matchItem);
    assert(finder.treeRows[4].match.displayLine == 42);

    finder.moveSelection(1);
    assert(finder.selectedIndex == 1);
    finder.moveSelection(-1);
    assert(finder.selectedIndex == 0);

    // References mode test
    finder.setReferencesMatches("openFile", finder.matches, "Test References");
    assert(finder.isReferencesMode);
    assert(finder.referencesSymbol == "openFile");
    assert(finder.referencesSourceLabel == "Test References");
    assert(finder.matches.length == 2);
    assert(finder.treeRows.length == 5);

    // Filter references
    finder.handleTextInput("bar");
    assert(finder.matches.length == 1);
    assert(finder.matches[0].filePath == "source/bar.d");
    assert(finder.treeRows.length == 3); // dirNode "source", fileNode "bar.d", matchItem

    // Clear filter
    ProjectFindContext ctx;
    finder.handleKeyDown(0x8, 0, ctx); // Backspace 'r'
    finder.handleKeyDown(0x8, 0, ctx); // Backspace 'a'
    finder.handleKeyDown(0x8, 0, ctx); // Backspace 'b'
    assert(finder.matches.length == 2);
    assert(finder.treeRows.length == 5);

    // Collapse directory via Left Arrow when selectedIndex == 0 (dirNode "source")
    finder.handleKeyDown(SDLK_LEFT, 0, ctx);
    assert(finder.treeRows.length == 1);
    assert(finder.treeRows[0].isExpanded == false);

    // Expand directory via Right Arrow
    finder.handleKeyDown(SDLK_RIGHT, 0, ctx);
    assert(finder.treeRows.length == 5);
    assert(finder.treeRows[0].isExpanded == true);
}
