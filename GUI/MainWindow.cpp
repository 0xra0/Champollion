#include "MainWindow.hpp"

#include <filesystem>
#include <fstream>
#include <future>
#include <chrono>
#include <ctime>
#include <algorithm>

#include <QListWidget>
#include <QLineEdit>
#include <QCheckBox>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QFileDialog>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QFormLayout>
#include <QGroupBox>
#include <QLabel>
#include <QFont>
#include <QDir>
#include <QFile>
#include <QScrollBar>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QUrl>
#include <QCoreApplication>
#include <QtConcurrent/QtConcurrent>

#include <fmt/format.h>

#include "Pex/Binary.hpp"
#include "Pex/FileReader.hpp"
#include "Decompiler/AsmCoder.hpp"
#include "Decompiler/PscCoder.hpp"
#include "Decompiler/StreamWriter.hpp"
#include "Champollion/CaselessCompare.h"

namespace fs = std::filesystem;

// ---- File processing helpers ----

struct FileResult {
    QStringList lines;
    bool failed      = false;
    bool isStarfield = false;
};

// Handles --print-info and --print-compile-time modes.
static FileResult processFileInfo(const fs::path& file, bool printCompileTime)
{
    FileResult result;
    Pex::Binary pex;
    try {
        Pex::FileReader reader(file.string());
        reader.read(pex);
    } catch (std::exception& ex) {
        result.lines.push_back(QString::fromStdString(
            fmt::format("ERROR: {} : {}", file.string(), ex.what())));
        result.failed = true;
        return result;
    }

    if (printCompileTime) {
        auto t = pex.getHeader().getCompilationTime();
        result.lines.push_back(QString::fromStdString(
            fmt::format("{}: {}", file.string(), t)));
        return result;
    }

    // print-info
    std::string gameType;
    switch (pex.getGameType()) {
        case Pex::Binary::SkyrimScript:    gameType = "Skyrim";    break;
        case Pex::Binary::Fallout4Script:  gameType = "Fallout 4"; break;
        case Pex::Binary::StarfieldScript: gameType = "Starfield"; break;
        default:                           gameType = "Unknown";   break;
    }
    auto   header = pex.getHeader();
    auto   t      = header.getCompilationTime();
    std::string hrtime = ctime(&t);
    hrtime.erase(hrtime.find_last_not_of("\n") + 1);

    result.lines.push_back(QString::fromStdString(fmt::format("Script:             {}", file.string())));
    result.lines.push_back(QString::fromStdString(fmt::format("  Game:             {}", gameType)));
    result.lines.push_back(QString::fromStdString(fmt::format("  Game Version:     {}.{}", header.getMajorVersion(), header.getMinorVersion())));
    result.lines.push_back(QString::fromStdString(fmt::format("  GameID:           {}", header.getGameID())));
    result.lines.push_back(QString::fromStdString(fmt::format("  Compilation Time: {} ({})", t, hrtime)));
    result.lines.push_back(QString::fromStdString(fmt::format("  Source File:      {}", header.getSourceFileName())));
    result.lines.push_back(QString::fromStdString(fmt::format("  User Name:        {}", header.getUserName())));
    result.lines.push_back(QString::fromStdString(fmt::format("  Computer Name:    {}", header.getComputerName())));
    result.lines.push_back({});
    return result;
}

// Handles normal decompilation (--psc, --asm, --trace, etc.)
static FileResult processOneFile(
    const fs::path& file,
    bool  outputAssembly,
    const fs::path& assemblyDir,
    bool  outputComment,
    bool  writeHeader,
    bool  traceDecompilation,
    bool  dumpTree,
    bool  decompileDebugFuncs,
    bool  debugLineComment,
    bool  recreateDirStructure,
    const fs::path& papyrusDir,
    const fs::path& parentDir)
{
    FileResult result;
    Pex::Binary pex;
    try {
        Pex::FileReader reader(file.string());
        reader.read(pex);
        pex.sort();
    } catch (std::exception& ex) {
        result.lines.push_back(QString::fromStdString(
            fmt::format("ERROR: {} : {}", file.string(), ex.what())));
        result.failed = true;
        return result;
    }

    result.isStarfield = (pex.getGameType() == Pex::Binary::StarfieldScript);

    if (outputAssembly) {
        fs::path asmFile = assemblyDir / file.filename();
        asmFile.replace_extension(".pas");
        try {
            std::ofstream asmStream(asmFile.string());
            Decompiler::AsmCoder asmCoder(new Decompiler::StreamWriter(asmStream));
            asmCoder.code(pex);
            result.lines.push_back(QString::fromStdString(
                fmt::format("{} disassembled to {}", file.string(), asmFile.string())));
        } catch (std::exception& ex) {
            result.lines.push_back(QString::fromStdString(
                fmt::format("ERROR (asm): {} : {}", file.string(), ex.what())));
            result.failed = true;
            fs::remove(asmFile);
        }
    }

    fs::path dir_structure;
    if (recreateDirStructure &&
        (pex.getGameType() == Pex::Binary::Fallout4Script ||
         pex.getGameType() == Pex::Binary::StarfieldScript) &&
        !pex.getObjects().empty())
    {
        std::string script_path = pex.getObjects()[0].getName().asString();
        std::replace(script_path.begin(), script_path.end(), ':', '/');
        dir_structure = fs::path(script_path).remove_filename();
    } else if (!parentDir.empty()) {
        dir_structure = fs::relative(file, parentDir).remove_filename();
    }

    fs::path basedir = dir_structure.empty() ? papyrusDir : (papyrusDir / dir_structure);
    if (!dir_structure.empty())
        fs::create_directories(basedir);

    fs::path pscName = file.filename();
    pscName.replace_extension(".psc");
    fs::path pscFile = basedir / pscName;

    try {
        std::ofstream pscStream(pscFile);
        if (pscStream.fail())
            throw std::runtime_error(fmt::format("Failed to open {} for writing", pscFile.string()));
        Decompiler::PscCoder pscCoder(
            new Decompiler::StreamWriter(pscStream),
            outputComment, writeHeader,
            traceDecompilation, dumpTree,
            decompileDebugFuncs, debugLineComment,
            papyrusDir.string());
        pscCoder.code(pex);
        result.lines.push_back(QString::fromStdString(
            fmt::format("{} decompiled to {}", file.string(), pscFile.string())));
    } catch (std::exception& ex) {
        result.lines.push_back(QString::fromStdString(
            fmt::format("ERROR: {} : {}", file.string(), ex.what())));
        result.failed = true;
        fs::remove(pscFile);
    }

    return result;
}

// ---- MainWindow ----

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent)
    , m_watcher(new QFutureWatcher<DecompileStats>(this))
{
    setupUi();
    setAcceptDrops(true);
    setWindowTitle("Champollion Papyrus Decompiler");
    connect(m_watcher, &QFutureWatcher<DecompileStats>::finished,
            this, &MainWindow::onDecompileFinished);
}

void MainWindow::setupUi()
{
    QWidget* central = new QWidget(this);
    setCentralWidget(central);
    QVBoxLayout* root = new QVBoxLayout(central);

    // Input
    QGroupBox* inputGroup = new QGroupBox("Input Files / Directories");
    QVBoxLayout* inputLayout = new QVBoxLayout(inputGroup);

    m_inputList = new QListWidget;
    m_inputList->setSelectionMode(QAbstractItemView::ExtendedSelection);
    m_inputList->setMinimumHeight(120);
    inputLayout->addWidget(m_inputList);

    QHBoxLayout* inputBtnRow = new QHBoxLayout;
    QPushButton* addFilesBtn = new QPushButton("Add Files...");
    QPushButton* addDirBtn   = new QPushButton("Add Directory...");
    QPushButton* clearBtn    = new QPushButton("Clear");
    inputBtnRow->addWidget(addFilesBtn);
    inputBtnRow->addWidget(addDirBtn);
    inputBtnRow->addWidget(clearBtn);
    inputBtnRow->addStretch();
    inputLayout->addLayout(inputBtnRow);

    connect(addFilesBtn, &QPushButton::clicked, this, &MainWindow::addFiles);
    connect(addDirBtn,   &QPushButton::clicked, this, &MainWindow::addDirectory);
    connect(clearBtn,    &QPushButton::clicked, this, &MainWindow::clearInputs);

    root->addWidget(inputGroup);

    // Output directories
    QGroupBox* outputGroup = new QGroupBox("Output");
    QFormLayout* outputLayout = new QFormLayout(outputGroup);

    QHBoxLayout* outputDirRow = new QHBoxLayout;
    m_outputDirEdit = new QLineEdit(QDir::currentPath());
    QPushButton* browseOutputBtn = new QPushButton("Browse...");
    outputDirRow->addWidget(m_outputDirEdit);
    outputDirRow->addWidget(browseOutputBtn);
    outputLayout->addRow("Decompiled (.psc):", outputDirRow);

    m_asmDirRow = new QWidget;
    QHBoxLayout* asmDirLayout = new QHBoxLayout(m_asmDirRow);
    asmDirLayout->setContentsMargins(0, 0, 0, 0);
    m_asmDirEdit = new QLineEdit(QDir::currentPath());
    QPushButton* browseAsmBtn = new QPushButton("Browse...");
    asmDirLayout->addWidget(m_asmDirEdit);
    asmDirLayout->addWidget(browseAsmBtn);
    outputLayout->addRow("Assembly (.pas):", m_asmDirRow);
    m_asmDirRow->setVisible(false);

    connect(browseOutputBtn, &QPushButton::clicked, this, &MainWindow::browseOutputDir);
    connect(browseAsmBtn,    &QPushButton::clicked, this, &MainWindow::browseAsmDir);

    root->addWidget(outputGroup);

    // Options
    QGroupBox* optGroup = new QGroupBox("Options");
    QVBoxLayout* optLayout = new QVBoxLayout(optGroup);

    QHBoxLayout* optRow1 = new QHBoxLayout;
    m_chkAssembly   = new QCheckBox("Output assembly (.pas)");
    m_chkComment    = new QCheckBox("Assembly in comments");
    m_chkHeader     = new QCheckBox("Write header");
    optRow1->addWidget(m_chkAssembly);
    optRow1->addWidget(m_chkComment);
    optRow1->addWidget(m_chkHeader);
    optRow1->addStretch();
    optLayout->addLayout(optRow1);

    QHBoxLayout* optRow2 = new QHBoxLayout;
    m_chkRecursive  = new QCheckBox("Recursive");
    m_chkParallel   = new QCheckBox("Parallel");
    m_chkVerbose    = new QCheckBox("Verbose");
    optRow2->addWidget(m_chkRecursive);
    optRow2->addWidget(m_chkParallel);
    optRow2->addWidget(m_chkVerbose);
    optRow2->addStretch();
    optLayout->addLayout(optRow2);

    QHBoxLayout* optRow3 = new QHBoxLayout;
    m_chkDebugFuncs   = new QCheckBox("Decompile debug functions");
    m_chkRecreateDirs = new QCheckBox("Recreate subdirectories");
    m_chkNoDebugLine  = new QCheckBox("No debug line comments");
    optRow3->addWidget(m_chkDebugFuncs);
    optRow3->addWidget(m_chkRecreateDirs);
    optRow3->addWidget(m_chkNoDebugLine);
    optRow3->addStretch();
    optLayout->addLayout(optRow3);

    QHBoxLayout* optRow4 = new QHBoxLayout;
    m_chkTrace    = new QCheckBox("Trace decompilation (--trace)");
    m_chkDumpTree = new QCheckBox("Dump tree (--no-dump-tree to disable)");
    m_chkDumpTree->setChecked(true);
    m_chkDumpTree->setEnabled(false);
    optRow4->addWidget(m_chkTrace);
    optRow4->addWidget(m_chkDumpTree);
    optRow4->addStretch();
    optLayout->addLayout(optRow4);

    connect(m_chkAssembly, &QCheckBox::toggled, m_asmDirRow,    &QWidget::setVisible);
    connect(m_chkTrace,    &QCheckBox::toggled, m_chkDumpTree,  &QCheckBox::setEnabled);
    connect(m_chkTrace,    &QCheckBox::toggled, [this](bool on) {
        if (!on) m_chkDumpTree->setChecked(true); // reset to default when trace is off
    });

    root->addWidget(optGroup);

    // Action buttons
    QHBoxLayout* btnRow = new QHBoxLayout;

    m_inspectBtn = new QPushButton("Show PEX Info");
    m_inspectBtn->setMinimumHeight(32);
    m_compileTimeBtn = new QPushButton("Show Compile Times");
    m_compileTimeBtn->setMinimumHeight(32);

    m_decompileBtn = new QPushButton("Decompile");
    m_decompileBtn->setMinimumHeight(36);
    QFont f = m_decompileBtn->font();
    f.setBold(true);
    m_decompileBtn->setFont(f);

    btnRow->addStretch();
    btnRow->addWidget(m_inspectBtn);
    btnRow->addWidget(m_compileTimeBtn);
    btnRow->addSpacing(16);
    btnRow->addWidget(m_decompileBtn);
    btnRow->addStretch();

    connect(m_decompileBtn,   &QPushButton::clicked, this, &MainWindow::startDecompile);
    connect(m_inspectBtn,     &QPushButton::clicked, this, &MainWindow::startInspect);
    connect(m_compileTimeBtn, &QPushButton::clicked, this, &MainWindow::startCompileTime);

    root->addLayout(btnRow);

    // PSC Repair (Starfield post-processing)
    QGroupBox* repairGroup = new QGroupBox("PSC Repair — Starfield (Decompiled_PSC_Repair by LBGSHI)");
    QVBoxLayout* repairLayout = new QVBoxLayout(repairGroup);

    QLabel* repairNote = new QLabel(
        "Fixes guard blocks, event sender types, fragment structure, whitespace, and more in "
        "Champollion-decompiled Starfield .psc files so they compile cleanly in the Creation Kit.\n"
        "Requires: PowerShell 5.1 (Windows) or pwsh / PowerShell Core (Linux/macOS).");
    repairNote->setWordWrap(true);
    repairNote->setStyleSheet("color: gray; font-size: small;");
    repairLayout->addWidget(repairNote);

    QFormLayout* repairForm = new QFormLayout;

    QHBoxLayout* repairInputRow = new QHBoxLayout;
    m_repairInputEdit = new QLineEdit;
    m_repairInputEdit->setPlaceholderText("Folder containing decompiled .psc files");
    QPushButton* browseRepairInputBtn = new QPushButton("Browse...");
    repairInputRow->addWidget(m_repairInputEdit);
    repairInputRow->addWidget(browseRepairInputBtn);
    repairForm->addRow("Input (.psc folder):", repairInputRow);

    QHBoxLayout* repairOutputRow = new QHBoxLayout;
    m_repairOutputEdit = new QLineEdit;
    m_repairOutputEdit->setPlaceholderText("Output root (default: sibling 'Processed' folder)");
    QPushButton* browseRepairOutputBtn = new QPushButton("Browse...");
    repairOutputRow->addWidget(m_repairOutputEdit);
    repairOutputRow->addWidget(browseRepairOutputBtn);
    repairForm->addRow("Output root:", repairOutputRow);

    repairLayout->addLayout(repairForm);

    QHBoxLayout* repairOptRow = new QHBoxLayout;
    m_chkRepairForce        = new QCheckBox("Force (overwrite existing output)");
    m_chkRepairIncludeFixed = new QCheckBox("IncludeFixed (process files already under OutRoot)");
    repairOptRow->addWidget(m_chkRepairForce);
    repairOptRow->addWidget(m_chkRepairIncludeFixed);
    repairOptRow->addStretch();
    repairLayout->addLayout(repairOptRow);

    m_runRepairBtn = new QPushButton("Run PSC Repair");
    m_runRepairBtn->setMinimumHeight(30);
    repairLayout->addWidget(m_runRepairBtn);

    connect(browseRepairInputBtn,  &QPushButton::clicked, this, &MainWindow::browseRepairInput);
    connect(browseRepairOutputBtn, &QPushButton::clicked, this, &MainWindow::browseRepairOutput);
    connect(m_runRepairBtn,        &QPushButton::clicked, this, &MainWindow::runPscRepair);

    root->addWidget(repairGroup);

    // Log (shared)
    QGroupBox* logGroup = new QGroupBox("Log");
    QVBoxLayout* logLayout = new QVBoxLayout(logGroup);
    m_logView = new QPlainTextEdit;
    m_logView->setReadOnly(true);
    m_logView->setMinimumHeight(150);
    QFont mono("Monospace");
    mono.setStyleHint(QFont::TypeWriter);
    m_logView->setFont(mono);
    logLayout->addWidget(m_logView);
    root->addWidget(logGroup);
}

void MainWindow::setActionButtonsEnabled(bool on)
{
    m_decompileBtn->setEnabled(on);
    m_inspectBtn->setEnabled(on);
    m_compileTimeBtn->setEnabled(on);
}

void MainWindow::addInputPath(const QString& path)
{
    for (int i = 0; i < m_inputList->count(); ++i)
        if (m_inputList->item(i)->text() == path)
            return;
    m_inputList->addItem(path);
}

void MainWindow::addFiles()
{
    const QStringList files = QFileDialog::getOpenFileNames(
        this, "Select PEX Files", QString(),
        "Papyrus Compiled (*.pex);;All Files (*)");
    for (const auto& f : files)
        addInputPath(f);
}

void MainWindow::addDirectory()
{
    const QString dir = QFileDialog::getExistingDirectory(this, "Select Directory");
    if (!dir.isEmpty())
        addInputPath(dir);
}

void MainWindow::clearInputs()
{
    m_inputList->clear();
}

void MainWindow::browseOutputDir()
{
    const QString dir = QFileDialog::getExistingDirectory(
        this, "Select Output Directory", m_outputDirEdit->text());
    if (!dir.isEmpty())
        m_outputDirEdit->setText(dir);
}

void MainWindow::browseAsmDir()
{
    const QString dir = QFileDialog::getExistingDirectory(
        this, "Select Assembly Output Directory", m_asmDirEdit->text());
    if (!dir.isEmpty())
        m_asmDirEdit->setText(dir);
}

void MainWindow::dragEnterEvent(QDragEnterEvent* event)
{
    if (event->mimeData()->hasUrls())
        event->acceptProposedAction();
}

void MainWindow::dropEvent(QDropEvent* event)
{
    for (const QUrl& url : event->mimeData()->urls())
        if (url.isLocalFile())
            addInputPath(url.toLocalFile());
}

void MainWindow::startDecompile()   { startRun(RunMode::Decompile);         }
void MainWindow::startInspect()     { startRun(RunMode::PrintInfo);         }
void MainWindow::startCompileTime() { startRun(RunMode::PrintCompileTime);  }

void MainWindow::startRun(RunMode mode)
{
    if (m_inputList->count() == 0) {
        m_logView->appendPlainText("No input files or directories specified.");
        return;
    }

    // Snapshot all UI state before going off-thread
    const bool outputAssembly      = m_chkAssembly->isChecked();
    const bool outputComment       = m_chkComment->isChecked();
    const bool writeHeader         = m_chkHeader->isChecked();
    const bool parallel            = m_chkParallel->isChecked();
    const bool recursive           = m_chkRecursive->isChecked();
    const bool recreateDirs        = m_chkRecreateDirs->isChecked();
    const bool decompileDebugFuncs = m_chkDebugFuncs->isChecked();
    const bool debugLineComment    = !m_chkNoDebugLine->isChecked();
    const bool verbose             = m_chkVerbose->isChecked();
    const bool traceDecompilation  = m_chkTrace->isChecked();
    const bool dumpTree            = traceDecompilation && m_chkDumpTree->isChecked();

    const fs::path papyrusDir(m_outputDirEdit->text().toStdString());
    const fs::path assemblyDir = outputAssembly
        ? fs::path(m_asmDirEdit->text().toStdString()) : fs::path();

    // Validate output dirs only for decompile mode
    if (mode == RunMode::Decompile) {
        std::error_code ec;
        fs::create_directories(papyrusDir, ec);
        if (ec) {
            m_logView->appendPlainText(QString("Cannot create output directory: %1")
                                       .arg(QString::fromStdString(ec.message())));
            return;
        }
        if (outputAssembly) {
            fs::create_directories(assemblyDir, ec);
            if (ec) {
                m_logView->appendPlainText(QString("Cannot create assembly directory: %1")
                                           .arg(QString::fromStdString(ec.message())));
                return;
            }
        }
    }

    // Collect all .pex files
    using FilePair = std::pair<fs::path, fs::path>;
    std::vector<FilePair> files;

    for (int i = 0; i < m_inputList->count(); ++i) {
        const fs::path inputPath(m_inputList->item(i)->text().toStdString());
        if (fs::is_directory(inputPath)) {
            if (recursive) {
                for (auto& entry : fs::recursive_directory_iterator(inputPath))
                    if (fs::is_regular_file(entry) &&
                        caselessCompare(entry.path().extension().string().c_str(), ".pex") == 0)
                        files.push_back({entry.path(), inputPath});
            } else {
                for (auto& entry : fs::directory_iterator(inputPath))
                    if (fs::is_regular_file(entry) &&
                        caselessCompare(entry.path().extension().string().c_str(), ".pex") == 0)
                        files.push_back({entry.path(), fs::path()});
            }
        } else if (fs::exists(inputPath)) {
            files.push_back({inputPath, fs::path()});
        }
    }

    if (files.empty()) {
        m_logView->appendPlainText("No .pex files found in the specified inputs.");
        return;
    }

    setActionButtonsEnabled(false);
    m_logView->clear();

    const bool isInfo        = (mode == RunMode::PrintInfo);
    const bool isCompileTime = (mode == RunMode::PrintCompileTime);

    if (isInfo)
        m_logView->appendPlainText(QString("Reading info from %1 file(s)...").arg((int)files.size()));
    else if (isCompileTime)
        m_logView->appendPlainText(QString("Reading compile times from %1 file(s)...").arg((int)files.size()));
    else
        m_logView->appendPlainText(QString("Processing %1 file(s)...").arg((int)files.size()));

    auto future = QtConcurrent::run([=]() -> DecompileStats {
        DecompileStats stats;
        stats.isInfoMode = isInfo || isCompileTime;
        auto start = std::chrono::steady_clock::now();

        auto accumulate = [&](FileResult r) {
            ++stats.total;
            if (r.failed)      ++stats.failed;
            if (r.isStarfield) stats.starfieldWarning = true;
            // match CLI: always show errors; show success lines only when verbose
            if (r.failed || verbose || stats.isInfoMode)
                stats.log += r.lines;
        };

        if (parallel) {
            std::vector<std::future<FileResult>> futures;
            futures.reserve(files.size());
            for (size_t i = 0; i < files.size(); ++i) {
                const fs::path file = files[i].first;
                const fs::path pdir = files[i].second;
                futures.push_back(std::async(std::launch::async, [=]() -> FileResult {
                    if (isInfo || isCompileTime)
                        return processFileInfo(file, isCompileTime);
                    return processOneFile(file, outputAssembly, assemblyDir,
                        outputComment, writeHeader, traceDecompilation, dumpTree,
                        decompileDebugFuncs, debugLineComment, recreateDirs,
                        papyrusDir, pdir);
                }));
            }
            for (auto& f : futures)
                accumulate(f.get());
        } else {
            for (size_t i = 0; i < files.size(); ++i) {
                const fs::path& file = files[i].first;
                const fs::path& pdir = files[i].second;
                if (isInfo || isCompileTime)
                    accumulate(processFileInfo(file, isCompileTime));
                else
                    accumulate(processOneFile(file, outputAssembly, assemblyDir,
                        outputComment, writeHeader, traceDecompilation, dumpTree,
                        decompileDebugFuncs, debugLineComment, recreateDirs,
                        papyrusDir, pdir));
            }
        }

        stats.elapsed = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
        return stats;
    });

    m_watcher->setFuture(future);
}

void MainWindow::onDecompileFinished()
{
    const DecompileStats stats = m_watcher->result();

    for (const QString& line : stats.log)
        m_logView->appendPlainText(line);

    if (!stats.isInfoMode) {
        m_logView->appendPlainText(
            QString("\n%1 file(s) processed in %2 s")
                .arg(stats.total)
                .arg(stats.elapsed, 0, 'f', 2));

        if (stats.failed > 0)
            m_logView->appendPlainText(
                QString("%1 file(s) failed to decompile.").arg(stats.failed));

        if (stats.total > 0 && stats.total != stats.failed) {
            const QString outDir = m_outputDirEdit->text();
            m_logView->appendPlainText(QString("Decompiled scripts written to: %1").arg(outDir));
            if (m_repairInputEdit->text().isEmpty())
                m_repairInputEdit->setText(outDir);
        }

        if (stats.starfieldWarning)
            m_logView->appendPlainText(
                "\n*** STARFIELD PRELIMINARY SYNTAX WARNING ***\n"
                "New Starfield features (Guard, TryGuard, GetMatchingStructs) use guessed-at syntax.\n"
                "Lines with guessed syntax are marked with ';***'.\n"
                "*** STARFIELD PRELIMINARY SYNTAX WARNING ***");
    } else {
        m_logView->appendPlainText(
            QString("\n%1 file(s) read in %2 s")
                .arg(stats.total)
                .arg(stats.elapsed, 0, 'f', 2));
        if (stats.failed > 0)
            m_logView->appendPlainText(
                QString("%1 file(s) could not be read.").arg(stats.failed));
    }

    m_logView->verticalScrollBar()->setValue(m_logView->verticalScrollBar()->maximum());
    setActionButtonsEnabled(true);
}

// ---- PSC Repair ----

QString MainWindow::findRepairScript() const
{
    const QStringList candidates = {
        QCoreApplication::applicationDirPath() + "/Decompiled_PSC_Repair.ps1",
        QDir::currentPath()                    + "/Decompiled_PSC_Repair.ps1",
    };
    for (const QString& p : candidates)
        if (QFile::exists(p)) return p;
    return {};
}

void MainWindow::browseRepairInput()
{
    const QString dir = QFileDialog::getExistingDirectory(
        this, "Select .psc Input Folder", m_repairInputEdit->text());
    if (!dir.isEmpty())
        m_repairInputEdit->setText(dir);
}

void MainWindow::browseRepairOutput()
{
    const QString dir = QFileDialog::getExistingDirectory(
        this, "Select Repair Output Root", m_repairOutputEdit->text());
    if (!dir.isEmpty())
        m_repairOutputEdit->setText(dir);
}

void MainWindow::runPscRepair()
{
    const QString scriptPath = findRepairScript();
    if (scriptPath.isEmpty()) {
        m_logView->appendPlainText(
            "ERROR: Decompiled_PSC_Repair.ps1 not found next to the executable or in the "
            "current working directory.");
        return;
    }

    const QString inputDir = m_repairInputEdit->text().trimmed();
    if (inputDir.isEmpty()) {
        m_logView->appendPlainText("ERROR: No input folder specified for PSC Repair.");
        return;
    }

#ifdef Q_OS_WIN
    const QString ps = "powershell";
#else
    const QString ps = "pwsh";
#endif

    QStringList args = {
        "-ExecutionPolicy", "Bypass",
        "-File", scriptPath,
        "-Path", inputDir,
    };
    const QString outputDir = m_repairOutputEdit->text().trimmed();
    if (!outputDir.isEmpty())
        args << "-OutRoot" << outputDir;
    if (m_chkRepairForce->isChecked())
        args << "-Force";
    if (m_chkRepairIncludeFixed->isChecked())
        args << "-IncludeFixed";

    if (m_repairProcess) {
        m_repairProcess->kill();
        m_repairProcess->deleteLater();
    }
    m_repairProcess = new QProcess(this);
    m_repairProcess->setProcessChannelMode(QProcess::SeparateChannels);

    connect(m_repairProcess, &QProcess::readyReadStandardOutput,
            this, &MainWindow::onRepairReadStdout);
    connect(m_repairProcess, &QProcess::readyReadStandardError,
            this, &MainWindow::onRepairReadStderr);
    connect(m_repairProcess, &QProcess::finished,
            this, &MainWindow::onRepairFinished);

    m_runRepairBtn->setEnabled(false);
    m_logView->appendPlainText(QString("\n--- PSC Repair: %1 ---").arg(ps + " " + args.join(" ")));
    m_repairProcess->start(ps, args);

    if (!m_repairProcess->waitForStarted(3000)) {
        m_logView->appendPlainText(
            QString("ERROR: Failed to start PowerShell (%1). "
                    "Install PowerShell Core (pwsh) or ensure it is in PATH.").arg(ps));
        m_runRepairBtn->setEnabled(true);
        m_repairProcess->deleteLater();
        m_repairProcess = nullptr;
    }
}

void MainWindow::onRepairReadStdout()
{
    const QString text = QString::fromLocal8Bit(m_repairProcess->readAllStandardOutput());
    for (const QString& line : text.split('\n', Qt::SkipEmptyParts))
        m_logView->appendPlainText(line.trimmed());
    m_logView->verticalScrollBar()->setValue(m_logView->verticalScrollBar()->maximum());
}

void MainWindow::onRepairReadStderr()
{
    const QString text = QString::fromLocal8Bit(m_repairProcess->readAllStandardError());
    for (const QString& line : text.split('\n', Qt::SkipEmptyParts))
        m_logView->appendPlainText("ERR: " + line.trimmed());
    m_logView->verticalScrollBar()->setValue(m_logView->verticalScrollBar()->maximum());
}

void MainWindow::onRepairFinished(int exitCode, QProcess::ExitStatus status)
{
    onRepairReadStdout();
    onRepairReadStderr();

    if (status == QProcess::CrashExit)
        m_logView->appendPlainText("PSC Repair: process crashed.");
    else if (exitCode != 0)
        m_logView->appendPlainText(QString("PSC Repair: exited with code %1.").arg(exitCode));
    else
        m_logView->appendPlainText("PSC Repair: complete.");

    m_logView->verticalScrollBar()->setValue(m_logView->verticalScrollBar()->maximum());
    m_runRepairBtn->setEnabled(true);
}
