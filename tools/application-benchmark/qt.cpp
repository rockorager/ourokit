#include <QApplication>
#include <QPushButton>
#include <QWidget>

int main(int argc, char **argv) {
    QApplication application(argc, argv);
    QApplication::setDesktopFileName("dev.ourokit.benchmark.qt");
    application.setApplicationName("Ourokit Qt benchmark");

    QWidget window;
    window.setWindowTitle("Qt benchmark");
    window.resize(480, 320);

    QPushButton button("Benchmark", &window);
    button.setFixedSize(160, 44);
    button.move(0, 0);
    QObject::connect(&button, &QPushButton::clicked, [&button]() {
        button.setText(button.text() == "Benchmark" ? "Clicked" : "Benchmark");
    });

    window.show();
    return application.exec();
}
