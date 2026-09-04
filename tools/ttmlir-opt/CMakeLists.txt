add_llvm_executable(ttmlir-opt ttmlir-opt.cpp)

llvm_update_compile_flags(ttmlir-opt)
target_link_libraries(ttmlir-opt PRIVATE TTMLIRCompilerStatic MLIROptLib)
target_link_libraries(ttmlir-opt PUBLIC coverage_config)

# BufferDeallocationPipelineOptions has a virtual base.  Its construction VTT
# is emitted as a weak symbol by MLIRBufferizationPipelines, which GNU ld may
# otherwise discard with --gc-sections.  Keep it so querying pipeline options
# (for example, with --help) cannot dereference a null VTT entry.
if(UNIX AND NOT APPLE)
  target_link_options(ttmlir-opt PRIVATE
    "LINKER:--undefined=_ZTTN4mlir13bufferization33BufferDeallocationPipelineOptionsE")
endif()

mlir_check_all_link_libraries(ttmlir-opt)

install(TARGETS ttmlir-opt DESTINATION ${CMAKE_INSTALL_BINDIR} COMPONENT Test EXCLUDE_FROM_ALL)
