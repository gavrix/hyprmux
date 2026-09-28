// Chromium helper process (GPU, renderer, network, ...). The bundle script
// copies this binary into "Hyprmux Helper*.app" bundles.
#import "ChromiumBridge.h"

int main(int argc, char *argv[]) {
    return HMChromiumHelperMain(argc, argv);
}
