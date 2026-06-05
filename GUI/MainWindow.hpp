#pragma once

#include <QMainWindow>
#include <QFutureWatcher>
#include <QProcess>
#include <QStringList>

class QListWidget;
class QLineEdit;
class QCheckBox;
class QPlainTextEdit;
class QPushButton;
class QWidget;

struct DecompileStats {
    int    total = 0;
    int    failed = 0;
    double elapsed = 0.0;
    bool   starfieldWarning = false;
    bool   isInfoMode = false;
    QStringList log;
};

class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);

protected:
    void dragEnterEvent(QDragEnterEvent* event) override;
    void dropEvent(QDropEvent* event) override;

private slots:
    // Decompile / inspect
    void addFiles();
    void addDirectory();
    void clearInputs();
    void browseOutputDir();
    void browseAsmDir();
    void startDecompile();
    void startInspect();
    void startCompileTime();
    void onDecompileFinished();

    // PSC Repair
    void browseRepairInput();
    void browseRepairOutput();
    void runPscRepair();
    void onRepairReadStdout();
    void onRepairReadStderr();
    void onRepairFinished(int exitCode, QProcess::ExitStatus status);

private:
    enum class RunMode { Decompile, PrintInfo, PrintCompileTime };

    void    setupUi();
    void    addInputPath(const QString& path);
    void    startRun(RunMode mode);
    void    setActionButtonsEnabled(bool on);
    QString findRepairScript() const;

    // Decompile widgets
    QListWidget*    m_inputList;
    QLineEdit*      m_outputDirEdit;
    QLineEdit*      m_asmDirEdit;
    QWidget*        m_asmDirRow;
    QCheckBox*      m_chkAssembly;
    QCheckBox*      m_chkComment;
    QCheckBox*      m_chkHeader;
    QCheckBox*      m_chkParallel;
    QCheckBox*      m_chkRecursive;
    QCheckBox*      m_chkVerbose;
    QCheckBox*      m_chkDebugFuncs;
    QCheckBox*      m_chkRecreateDirs;
    QCheckBox*      m_chkNoDebugLine;
    QCheckBox*      m_chkTrace;
    QCheckBox*      m_chkDumpTree;
    QPlainTextEdit* m_logView;
    QPushButton*    m_decompileBtn;
    QPushButton*    m_inspectBtn;
    QPushButton*    m_compileTimeBtn;
    QFutureWatcher<DecompileStats>* m_watcher;

    // PSC Repair widgets
    QLineEdit*   m_repairInputEdit;
    QLineEdit*   m_repairOutputEdit;
    QCheckBox*   m_chkRepairForce;
    QCheckBox*   m_chkRepairIncludeFixed;
    QPushButton* m_runRepairBtn;
    QProcess*    m_repairProcess = nullptr;
};
