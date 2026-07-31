cmake_minimum_required(VERSION 3.22)

set(TRAINER_DEFAULT_VERSION "1.0.0")
if(DEFINED ENV{TRAINER_PROJECT_VERSION} AND NOT "$ENV{TRAINER_PROJECT_VERSION}" STREQUAL "")
    set(TRAINER_DEFAULT_VERSION "$ENV{TRAINER_PROJECT_VERSION}")
endif()
set(TRAINER_PROJECT_VERSION "${TRAINER_DEFAULT_VERSION}" CACHE STRING "BC250 Trainer semantic version")
if(NOT TRAINER_PROJECT_VERSION MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    message(FATAL_ERROR "TRAINER_PROJECT_VERSION must use MAJOR.MINOR.PATCH format")
endif()
project(bc250-trainer VERSION "${TRAINER_PROJECT_VERSION}" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 6.4 REQUIRED COMPONENTS Core Gui Quick QuickControls2 DBus Multimedia)

add_executable(bc250-trainer
    src/main.cpp
    src/Bc250Bridge.cpp
    src/Bc250Bridge.h
    src/MediaController.cpp
    src/MediaController.h
    resources.qrc
)

target_link_libraries(bc250-trainer PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::DBus
    Qt6::Multimedia
)

target_compile_definitions(bc250-trainer PRIVATE
    BC250_TRAINER_VERSION="${PROJECT_VERSION}"
)

include(CTest)
if(BUILD_TESTING)
    find_package(Qt6 6.4 QUIET COMPONENTS Test)
    if(TARGET Qt6::Test)
        add_executable(bc250-bridge-tests
            tests/tst_Bc250Bridge.cpp
            src/Bc250Bridge.cpp
            src/Bc250Bridge.h
        )
        target_include_directories(bc250-bridge-tests PRIVATE src)
        target_link_libraries(bc250-bridge-tests PRIVATE Qt6::Core Qt6::DBus Qt6::Test)
        add_test(NAME bridge-native COMMAND bc250-bridge-tests)

        add_executable(media-controller-tests
            tests/tst_MediaController.cpp
            src/MediaController.cpp
            src/MediaController.h
        )
        target_include_directories(media-controller-tests PRIVATE src)
        target_link_libraries(media-controller-tests PRIVATE
            Qt6::Core
            Qt6::Multimedia
            Qt6::Test
        )
        add_test(NAME media-native COMMAND media-controller-tests)
    endif()
endif()

set(QT6_TOOL_HINTS "/usr/lib/qt6/bin")
if(TARGET Qt6::qmake)
    get_target_property(QT6_QMAKE_EXECUTABLE Qt6::qmake IMPORTED_LOCATION)
    get_filename_component(QT6_QMAKE_DIRECTORY "${QT6_QMAKE_EXECUTABLE}" DIRECTORY)
    list(PREPEND QT6_TOOL_HINTS "${QT6_QMAKE_DIRECTORY}")
endif()

find_program(QMLLINT_EXECUTABLE NAMES qmllint qmllint6 HINTS ${QT6_TOOL_HINTS} NO_DEFAULT_PATH)
if(NOT QMLLINT_EXECUTABLE)
    unset(QMLLINT_EXECUTABLE CACHE)
    find_program(QMLLINT_EXECUTABLE NAMES qmllint6)
endif()
file(GLOB_RECURSE TRAINER_QML_FILES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/qml/*.qml")
if(QMLLINT_EXECUTABLE)
    set(QMLLINT_ARGUMENTS --unqualified disable)
    if(NOT APPLE)
        list(APPEND QMLLINT_ARGUMENTS
            --import info
            --property info
            --type info
            --deferred-property-id info
        )
    endif()
    add_custom_target(qml-lint
        COMMAND "${QMLLINT_EXECUTABLE}"
            ${QMLLINT_ARGUMENTS}
            ${TRAINER_QML_FILES}
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        COMMENT "Linting BC250 Trainer QML"
        VERBATIM
    )
endif()

find_program(QMLTESTRUNNER_EXECUTABLE NAMES qmltestrunner qmltestrunner6 HINTS ${QT6_TOOL_HINTS} NO_DEFAULT_PATH)
if(NOT QMLTESTRUNNER_EXECUTABLE)
    unset(QMLTESTRUNNER_EXECUTABLE CACHE)
    find_program(QMLTESTRUNNER_EXECUTABLE NAMES qmltestrunner6)
endif()
if(BUILD_TESTING AND QMLTESTRUNNER_EXECUTABLE)
    add_test(NAME qml-components
        COMMAND "${QMLTESTRUNNER_EXECUTABLE}"
            -input "${CMAKE_CURRENT_SOURCE_DIR}/tests/qml"
            -import "${CMAKE_CURRENT_SOURCE_DIR}/qml"
            -platform offscreen
    )
    set_tests_properties(qml-components PROPERTIES
        ENVIRONMENT "QT_QUICK_BACKEND=software;QT_QUICK_CONTROLS_STYLE=Fusion"
    )
    add_custom_target(qml-tests
        COMMAND "${CMAKE_CTEST_COMMAND}" --output-on-failure -R "^qml-components$"
        DEPENDS bc250-trainer
        VERBATIM
    )
endif()

find_program(QMLSCENE6_EXECUTABLE NAMES qmlscene qmlscene6 HINTS ${QT6_TOOL_HINTS} NO_DEFAULT_PATH)
if(NOT QMLSCENE6_EXECUTABLE)
    unset(QMLSCENE6_EXECUTABLE CACHE)
    find_program(QMLSCENE6_EXECUTABLE NAMES qmlscene6)
endif()
if(BUILD_TESTING AND QMLSCENE6_EXECUTABLE)
    add_test(NAME qml-qt6-offscreen-smoke
        COMMAND "${QMLSCENE6_EXECUTABLE}"
            -platform offscreen
            -I "${CMAKE_CURRENT_SOURCE_DIR}/qml"
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/qml/Qt6Smoke.qml"
    )
    set_tests_properties(qml-qt6-offscreen-smoke PROPERTIES
        TIMEOUT 10
        ENVIRONMENT "QT_QUICK_BACKEND=software"
    )
    add_custom_target(qml-smoke
        COMMAND "${CMAKE_CTEST_COMMAND}" --output-on-failure -R "^qml-qt6-offscreen-smoke$"
        VERBATIM
    )
endif()

add_test(NAME offscreen-startup
    COMMAND bc250-trainer --mock --smoke-test
)
set_tests_properties(offscreen-startup PROPERTIES
    TIMEOUT 10
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software"
)
add_custom_target(smoke
    COMMAND "${CMAKE_CTEST_COMMAND}" --output-on-failure -R "^offscreen-startup$"
    DEPENDS bc250-trainer
    VERBATIM
)

set(EXEC bc250-trainer)
configure_file(
    packaging/io.github.keyboardspecialist.bc250trainer.desktop.in
    io.github.keyboardspecialist.bc250trainer.desktop
    @ONLY
)

install(TARGETS bc250-trainer RUNTIME DESTINATION bin)
install(DIRECTORY tracks/ DESTINATION share/bc250-trainer FILES_MATCHING PATTERN "*.mp3")
install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/io.github.keyboardspecialist.bc250trainer.desktop"
    DESTINATION share/applications
)
install(FILES packaging/io.github.keyboardspecialist.bc250trainer.svg
    DESTINATION share/icons/hicolor/scalable/apps
)
install(FILES packaging/io.github.keyboardspecialist.bc250trainer.metainfo.xml
    DESTINATION share/metainfo
)
