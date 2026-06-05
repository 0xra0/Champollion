#include <QApplication>
#include "MainWindow.hpp"

int main(int argc, char* argv[])
{
    QApplication app(argc, argv);
    app.setApplicationName("ChampollionGUI");
    app.setApplicationDisplayName("Champollion Papyrus Decompiler");

    MainWindow window;
    window.resize(900, 700);
    window.show();

    return app.exec();
}
