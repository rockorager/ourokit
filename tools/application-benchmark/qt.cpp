#include <QApplication>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QVBoxLayout>
#include <QWidget>
#include <cstring>

int main(int argc, char **argv) {
    const bool settings = argc == 2 && std::strcmp(argv[1], "--settings") == 0;
    if (settings) argc = 1;
    QApplication application(argc, argv);
    QApplication::setDesktopFileName("dev.ourokit.benchmark.qt");
    application.setApplicationName("Ourokit Qt benchmark");

    QWidget window;
    if (settings) {
        window.setWindowTitle("Qt settings benchmark");
        window.resize(560, 360);
        auto *column = new QVBoxLayout(&window);
        column->setContentsMargins(12, 12, 12, 12);
        column->setSpacing(12);
        column->addWidget(new QLabel("Ourokit controls"));
        auto *status = new QLabel("Pressed 0 times");
        column->addWidget(status);
        auto *row = new QHBoxLayout();
        row->setSpacing(8);
        auto *increment = new QPushButton("Increment");
        increment->setFixedSize(160, 40);
        QObject::connect(increment, &QPushButton::clicked, [status]() {
            static unsigned int count = 0;
            status->setText(QString("Pressed %1 times").arg(++count));
        });
        auto *disabled = new QPushButton("Disabled");
        disabled->setFixedSize(160, 40);
        disabled->setEnabled(false);
        row->addWidget(increment);
        row->addWidget(disabled);
        row->addStretch();
        column->addLayout(row);
        column->addStretch();
        window.show();
        return application.exec();
    }
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
