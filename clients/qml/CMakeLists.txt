cmake_minimum_required(VERSION 3.21)
project(hyprmux-qml LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui GuiPrivate Qml Quick QuickPrivate Test)
qt_standard_project_setup(REQUIRES 6.6)

# XPC objects as plain C pointers: the Connection releases them by hand, and ARC
# in the Metal code doesn't manage them.
add_compile_definitions(OS_OBJECT_USE_OBJC=0)
set(CMAKE_OBJCXX_FLAGS "${CMAKE_OBJCXX_FLAGS} -fobjc-arc")

# Logic without the window system or Metal, shared with the tests.
add_library(hyprmux-qml-core STATIC
    src/qml/Attribution.h src/qml/Attribution.cpp
    src/qml/PluginSettings.h src/qml/PluginSettings.cpp
    src/qml/WindowUI.h src/qml/WindowUI.cpp
    src/scene/KeyMap.h src/scene/KeyMap.mm
)
target_link_libraries(hyprmux-qml-core PUBLIC Qt6::Core Qt6::Gui)

qt_add_executable(hyprmux-qml
    src/main.mm
    src/Host.h src/Host.mm
    src/Trace.h
    src/protocol/Connection.h src/protocol/Connection.mm
    src/render/Swapchain.h src/render/Swapchain.mm
    src/scene/InputBridge.h src/scene/InputBridge.mm
    src/scene/Scene.h src/scene/Scene.mm
)
set_target_properties(hyprmux-qml PROPERTIES MACOSX_BUNDLE OFF)

# The `Hyprmux` QML module, compiled into the host. Qt generates its qmltypes from
# the QML_ELEMENT declarations: qmllint and qmlls read it (see docs/PLUGINS.md).
qt_add_qml_module(hyprmux-qml
    URI Hyprmux
    VERSION 1.0
    SOURCES
        src/qml/BarItem.h
        src/qml/BarPopup.h
        src/qml/Dialogs.h src/qml/Dialogs.cpp
        src/qml/Files.h src/qml/Files.cpp
        src/qml/Menus.h src/qml/Menus.cpp
        src/qml/HyprmuxApp.h
        src/qml/HyprmuxWindow.h src/qml/HyprmuxWindow.cpp
        src/qml/Notifier.h src/qml/Notifier.cpp
        src/qml/Plugin.h src/qml/Plugin.cpp
        src/qml/System.h src/qml/System.cpp
        src/qml/Theme.h src/qml/Theme.cpp
        src/qml/Tiles.h src/qml/Tiles.mm
)
target_include_directories(hyprmux-qml PRIVATE src src/qml)
target_link_libraries(hyprmux-qml PRIVATE
    hyprmux-qml-core
    Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Qml Qt6::Quick Qt6::QuickPrivate
    "-framework AppKit" "-framework Metal" "-framework IOSurface" "-framework IOKit"
)

# Tests: `ctest --test-dir build`.
enable_testing()
qt_add_executable(hyprmux-qml-tests tests/main.cpp tests/AttributionTests.cpp tests/KeyMapTests.cpp tests/PluginSettingsTests.cpp tests/WindowUITests.cpp)
target_include_directories(hyprmux-qml-tests PRIVATE src)
target_link_libraries(hyprmux-qml-tests PRIVATE hyprmux-qml-core Qt6::Test)
add_test(NAME hyprmux-qml-tests COMMAND hyprmux-qml-tests)
