using CImGui
using .CImGui: GLFWBackend, OpenGLBackend
using .GLFWBackend: GLFW
using .OpenGLBackend: ModernGL
using Colors: RGBA
using Base: @kwdef

@kwdef mutable struct InputText
    label::String = ""
    buf::String = ""
    buf_size::Int = 32
end

@kwdef mutable struct Button
    title = "Button"
    callback = nothing
end

function didClick(f, btn::Button)
    btn.callback = f
end

macro cstatic_var(exprs...)
    global_sym = gensym(:cstatic_var)
    expr = exprs[1]
    epilogue = exprs[end]
    l, r = expr.args
    insert!(epilogue.args, 1, quote
        global $global_sym
        $l = $global_sym
    end)
    push!(epilogue.args, :($global_sym = $l))
    quote
        global $global_sym = $(esc(r))
        $(esc(epilogue))
    end
end

# CImGui.InputText
function imgui_control_item(ctx, item::InputText)
    null = '\0'
    nullpad_buf = rpad(item.buf, item.buf_size, null)
    value = @cstatic_var buf=nullpad_buf begin
        changed = CImGui.InputText(item.label, buf, item.buf_size)
    end
    if changed
        item.buf, = split(value, null)
    end
end

module Mouse

function leftClick(item)
    if item.callback !== nothing
        event = (action=leftClick, )
        item.callback(event)
    end
end

end # module Mouse

function imgui_control_item(ctx, item::Button)
    CImGui.Button(item.title) && @async Mouse.leftClick(item)
end

error_callback(err::GLFW.GLFWError) = @error "GLFW ERROR: code $(err.code) msg: $(err.description)"

exit_on_esc() = true

function custom_key_callback(window::GLFW.Window, key, scancode, action, mods)
    exit_on_esc() && action == GLFW.PRESS && key == GLFW.KEY_ESCAPE && GLFW.SetWindowShouldClose(window, true)
    GLFWBackend.ImGui_ImplGlfw_KeyCallback(window, key, scancode, action, mods)
end



abstract type UIApplication end
abstract type UIWindow end

env = Dict{Ptr{Cvoid},UIApplication}()

function runloop(glwin, ctx, glsl_version, push_window, app::UIApplication)
    GLFWBackend.ImGui_ImplGlfw_InitForOpenGL(glwin, true)
    OpenGLBackend.ImGui_ImplOpenGL3_Init(glsl_version)
    GLFW.SetKeyCallback(glwin, custom_key_callback)
    GLFW.SetErrorCallback(error_callback)
    try
        quantum = 0.016666666f0
        bgcolor = nothing
        function refresh() 
            bgcolor = app.props[:bgcolor]
        end
        refresh()
        while !GLFW.WindowShouldClose(glwin)
            yield()
            GLFW.WaitEvents(quantum)
            OpenGLBackend.ImGui_ImplOpenGL3_NewFrame()
            GLFWBackend.ImGui_ImplGlfw_NewFrame()
            CImGui.NewFrame()
            push_window(app)
            CImGui.Render()
            display_w, display_h = GLFW.GetFramebufferSize(glwin)
            ModernGL.glViewport(0, 0, display_w, display_h)
            if app.dirty
                refresh()
                app.dirty = false
            end
            ModernGL.glClearColor(bgcolor.r, bgcolor.g, bgcolor.b, bgcolor.alpha)
            ModernGL.glClear(ModernGL.GL_COLOR_BUFFER_BIT)
            OpenGLBackend.ImGui_ImplOpenGL3_RenderDrawData(CImGui.GetDrawData())
            GLFW.SwapBuffers(glwin)
        end
    catch e
        @error "Error in renderloop!" exception=e
        Base.show_backtrace(stderr, catch_backtrace())
    finally
        OpenGLBackend.ImGui_ImplOpenGL3_Shutdown()
        GLFWBackend.ImGui_ImplGlfw_Shutdown()
        CImGui.DestroyContext(ctx)
        GLFW.HideWindow(glwin)
        GLFW.DestroyWindow(glwin)
        delete!(env, glwin.handle)
        notify(app.closenotify)
    end
end # function runloop()

function create_window(app, vsync=true)
    @static if Sys.isapple()
        # OpenGL 3.2 + GLSL 150
        glsl_version = 150
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 3)
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 2)
        GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE) # 3.2+ only
        GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, ModernGL.GL_TRUE) # required on Mac
    else
        # OpenGL 3.0 + GLSL 130
        glsl_version = 130
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 3)
        GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 0)
        # GLFW.WindowHint(GLFW.OPENGL_PROFILE, GLFW.OPENGL_CORE_PROFILE) # 3.2+ only
        # GLFW.WindowHint(GLFW.OPENGL_FORWARD_COMPAT, ModernGL.GL_TRUE) # 3.0+ only
    end
    window = GLFW.CreateWindow(app.props[:frame].width, app.props[:frame].height, app.props[:title])
    GLFW.MakeContextCurrent(window)
    vsync && GLFW.SwapInterval(1)
    ctx = CImGui.CreateContext()
    (window, ctx, glsl_version)
end

custom_fonts(::Any) = nothing



@kwdef struct Window <: UIWindow
    title = "Title"
    items = []
    show_window_closing_widget = true
    window_flags = CImGui.ImGuiWindowFlags(0)
end

function setup_window(ctx, window::Window)
    p_open = Ref(window.show_window_closing_widget)
    CImGui.Begin(window.title, p_open, window.window_flags) || (CImGui.End(); return)
    for item in window.items
        imgui_control_item(ctx, item)
    end
    CImGui.End()
end


"""
    Application(; title::String="App",
                  frame::NamedTuple{(:width,:height)} = (width=400, height=300),
                  windows = UIWindow[Window(title="Title", frame=(x=0,y=0,frame...))],
                  bgcolor = RGBA(0.10, 0.18, 0.24, 1),
                  closenotify = Condition())
"""
mutable struct Application <: UIApplication
    props::Dict{Symbol,Any}
    windows::Vector{UIWindow}
    imctx::Union{Nothing,Ptr}
    task::Union{Nothing,Task}
    closenotify::Condition
    dirty::Bool

    function Application(; title::String="App",
                           frame::NamedTuple{(:width,:height)} = (width=400, height=300),
                           windows = UIWindow[Window(title="Title", frame=(x=0,y=0,frame...))],
                           bgcolor = RGBA(0.10, 0.18, 0.24, 1),
                           closenotify::Condition = Condition())
        glwin = GLFW.GetCurrentContext()
        glwin.handle !== C_NULL && haskey(env, glwin.handle) && return env[glwin.handle]
        props = Dict(:title => title, :frame => frame, :bgcolor => bgcolor)
        app = new(props, windows, nothing, nothing, closenotify, true)
        create_app(app)
    end
end


function properties(::A) where {A <: UIApplication}
    (:title, :frame, :bgcolor, )
end

function Base.getproperty(app::A, prop::Symbol) where {A <: UIApplication}
    if prop in fieldnames(A)
        getfield(app, prop)
    elseif prop in properties(app)
        app.props[prop]
    else
        throw(KeyError(prop))
    end
end

function Base.setproperty!(app::A, prop::Symbol, val) where {A <: UIApplication}
    if prop in fieldnames(Application)
        setfield!(app, prop, val)
    elseif prop in properties(app)
        app.props[prop] = val
        glwin = GLFW.GetCurrentContext()
        if glwin.handle !== C_NULL
            if prop === :title
                GLFW.SetWindowTitle(glwin, val)
            elseif prop === :frame
                GLFW.SetWindowSize(glwin, val.width, val.height)
            elseif prop === :bgcolor
                app.dirty = true
            end
        end
    else
        throw(KeyError(prop))
    end
end

function setup_app(app::UIApplication)
    for window in app.windows
        setup_window(app.imctx, window)
    end
end

function resume(app::UIApplication)
    glwin = GLFW.GetCurrentContext()
    glwin.handle !== C_NULL && haskey(env, glwin.handle) && return nothing
    create_app(app)
    nothing
end

function pause(app::UIApplication)
    glwin = GLFW.GetCurrentContext()
    glwin.handle !== C_NULL && GLFW.SetWindowShouldClose(glwin, true)
end

function create_app(app::UIApplication)
    glwin, imctx, glsl_version = create_window(app)
    app.imctx = imctx
    custom_fonts(app)
    task = @async runloop(glwin, imctx, glsl_version, setup_app, app)
    app.task = task
    env[glwin.handle] = app
    app
end




function custom_fonts(::Application)
    fonts = CImGui.GetIO().Fonts
    glyph_ranges = CImGui.GetGlyphRangesKorean(fonts)
    CImGui.AddFontFromFileTTF(fonts, "IropkeBatangM.ttf", 20, C_NULL, glyph_ranges)
end

input1 = InputText(label="제목", buf="buf")
button1 = Button(title = "버튼")

didClick(button1) do event
    println("buf: ", event)
end
window1 = Window(items = [input1, button1])
app = Application(windows = [window1])

Base.JLOptions().isinteractive==0 && wait(app.closenotify)
