// Runs every test class; the exit status counts the failures.
#include <QtCore/QCoreApplication>

int runAttributionTests(int argc, char **argv);
int runKeyMapTests(int argc, char **argv);
int runPluginSettingsTests(int argc, char **argv);
int runWindowUITests(int argc, char **argv);
int runFrameStatsTests(int argc, char **argv);
int runFrameDriverTests(int argc, char **argv);

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    int failed = 0;
    failed += runAttributionTests(argc, argv);
    failed += runKeyMapTests(argc, argv);
    failed += runPluginSettingsTests(argc, argv);
    failed += runWindowUITests(argc, argv);
    failed += runFrameStatsTests(argc, argv);
    failed += runFrameDriverTests(argc, argv);
    return failed;
}
