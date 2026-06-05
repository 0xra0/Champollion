find_package(Qt6 REQUIRED COMPONENTS Widgets Concurrent)
qt_standard_project_setup()

# Copy the bundled PSC repair script so it ships alongside the GUI.
set(PS1_SRC "${CMAKE_SOURCE_DIR}/Decompiled_PSC_Repair.ps1")
set(PS1_OUT "${CMAKE_CURRENT_BINARY_DIR}/Decompiled_PSC_Repair.ps1")

add_custom_command(
    OUTPUT  "${PS1_OUT}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${PS1_SRC}" "${PS1_OUT}"
    DEPENDS "${PS1_SRC}"
    COMMENT "Copying Decompiled_PSC_Repair.ps1"
)
add_custom_target(CopyPscRepair ALL DEPENDS "${PS1_OUT}")

qt_add_executable(ChampollionGUI
    main.cpp
    MainWindow.cpp
    MainWindow.hpp
)

add_dependencies(ChampollionGUI CopyPscRepair)

# Copy the script next to the binary after each build so it is findable at runtime.
add_custom_command(TARGET ChampollionGUI POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${PS1_OUT}"
        "$<TARGET_FILE_DIR:ChampollionGUI>/Decompiled_PSC_Repair.ps1"
    COMMENT "Copying Decompiled_PSC_Repair.ps1 to output directory"
)

set_target_properties(ChampollionGUI PROPERTIES
    WIN32_EXECUTABLE TRUE
    MACOSX_BUNDLE TRUE
)

target_include_directories(ChampollionGUI PRIVATE
    ${CMAKE_SOURCE_DIR}
)

target_link_libraries(ChampollionGUI PRIVATE
    Qt6::Widgets
    Qt6::Concurrent
    Decompiler
    Pex
    fmt::fmt
)

install(TARGETS ChampollionGUI)
install(FILES "${PS1_OUT}" DESTINATION ".")
