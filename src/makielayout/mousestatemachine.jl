# TODO
# - adjust PriorityObservable to be able to see whether an event has been consumed
# - make all handlers here PriorityObservables
# - default this to max priority
# - consume if any handler consumes
# - also maybe removes dealing with mousebuttonstate

module MouseEventTypes
    @enum MouseEventType begin
        out
        enter
        over
        leftdown
        rightdown
        middledown
        leftup
        rightup
        middleup
        leftdragstart
        rightdragstart
        middledragstart
        leftdrag
        rightdrag
        middledrag
        leftdragstop
        rightdragstop
        middledragstop
        leftclick
        rightclick
        middleclick
        leftdoubleclick
        rightdoubleclick
        middledoubleclick
        downoutside
    end
    export MouseEventType
end

using .MouseEventTypes

"""
    MouseEvent

Describes a mouse state change.
Fields:
- `type`: MouseEventType
- `t`: Time of the event
- `data`: Mouse position in data coordinates
- `px`: Mouse position in px relative to scene origin
- `prev_t`: Time of previous event
- `prev_data`: Previous mouse position in data coordinates
- `prev_px`: Previous mouse position in data coordinates
"""
struct MouseEvent
    type::MouseEventType
    t::Float64
    data::Point2f0
    px::Point2f0
    prev_t::Float64
    prev_data::Point2f0
    prev_px::Point2f0
end

struct MouseEventHandle
    obs::Observable{MouseEvent}
    observerfuncs::Vector{<:Observables.ObserverFunction}
end

"""
    clear!(handle::MouseEventHandle)

Cut observable connections to the scene and remove any listeners to the mouse events.
"""
function clear!(handle::MouseEventHandle)
    foreach(Observables.off, handle.observerfuncs)
    empty!(handle.observerfuncs)
    empty!(handle.obs.listeners)
    nothing
end


for eventtype in instances(MouseEventType)
    onfunctionname = Symbol("onmouse" * String(Symbol(eventtype)))
    @eval begin

        """
        Executes the function f whenever the `MouseEventHandle`'s observable is set to
        a MouseEvent with `event.type === $($eventtype)`.
        """
        function $onfunctionname(f, mev::MouseEventHandle)
            on(mev.obs) do event
                if event.type === $eventtype
                    f(event)
                end
            end
        end
        export $onfunctionname
    end
end


"""
    addmouseevents!(scene, elements...)

Returns a `MouseEventHandle` with an observable inside which is triggered by all mouse
interactions with the `scene` and optionally restricted to all given
plot objects in `elements`.

To react to mouse events, use the onmouse... handlers.

Example:

```
mouseevents = addmouseevents!(scene, scatterplot)

onmouseleftclick(mouseevents) do event
    # do something with the mouseevent
end
```
"""
function addmouseevents!(scene, elements...; priority = Int8(0))

    Mouse = AbstractPlotting.Mouse
    dblclick_max_interval = 0.2    

    mouseevent = Node{MouseEvent}(MouseEvent(MouseEventTypes.out, 0.0, Point2f0(0, 0), Point2f0(0, 0), 0.0, Point2f0(0, 0), Point2f0(0, 0)))

    is_mouse_over_relevant_area() = isempty(elements) ? AbstractPlotting.is_mouseinside(scene) : mouseover(scene, elements...)


    # initialize state variables
    last_mouseevent = Ref{Mouse.DragEnum}(Mouse.notpressed)
    prev_data = Ref(mouseposition(scene))
    prev_px = Ref(AbstractPlotting.mouseposition_px(scene))
    mouse_downed_inside = Ref(false)
    mouse_downed_button = Ref{Optional{Mouse.Button}}(nothing)
    drag_ongoing = Ref(false)
    mouse_was_inside = Ref(false)
    prev_t = Ref(0.0)
    t_last_click = Ref(0.0)
    b_last_click = Ref{Optional{Mouse.Button}}(nothing)
    last_click_was_double = Ref(false)


    # react to mouse position changes
    mousepos_observerfunc = on(events(scene).mouseposition, priority=priority) do mp

        t = time()
        data = mouseposition(scene)
        px = AbstractPlotting.mouseposition_px(scene)
        mouse_inside = is_mouse_over_relevant_area()
            
        # last_mouseevent can only be up or down

        # mouse moved while being pressed
        # this can mean a new drag started, or a drag continues if it is ongoing.
        # it can also mean that a drag that started outside and isn't related to this
        # object is going across it and should be ignored here
        if last_mouseevent[] == Mouse.down

            if drag_ongoing[]
                # continue the drag
                event = @match mouse_downed_button[] begin
                    Mouse.left => MouseEventTypes.leftdrag
                    Mouse.right => MouseEventTypes.rightdrag
                    Mouse.middle => MouseEventTypes.middledrag
                    x => error("No recognized mouse button $x")
                end
                mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])
            else
                # mouse was downed inside but no drag is ongoing
                # that means a drag started
                if mouse_downed_inside[]
                    drag_ongoing[] = true
                    event = @match mouse_downed_button[] begin
                        Mouse.left => MouseEventTypes.leftdragstart
                        Mouse.right => MouseEventTypes.rightdragstart
                        Mouse.middle => MouseEventTypes.middledragstart
                        x => error("No recognized mouse button $x")
                    end
                    mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])

                    event = @match mouse_downed_button[] begin
                        Mouse.left => MouseEventTypes.leftdrag
                        Mouse.right => MouseEventTypes.rightdrag
                        Mouse.middle => MouseEventTypes.middledrag
                        x => error("No recognized mouse button $x")
                    end
                    mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])
                end
            end
        else
            if mouse_inside
                if mouse_was_inside[]
                    mouseevent[] = MouseEvent(MouseEventTypes.over, t, data, px, prev_t[], prev_data[], prev_px[])
                else
                    mouseevent[] = MouseEvent(MouseEventTypes.enter, t, data, px, prev_t[], prev_data[], prev_px[])
                end
            else
                if mouse_was_inside[]
                    mouseevent[] = MouseEvent(MouseEventTypes.out, t, data, px, prev_t[], prev_data[], prev_px[])
                end
            end
        end

        mouse_was_inside[] = mouse_inside
        prev_data[] = data
        prev_px[] = px
        prev_t[] = t
        return false
    end

    
    # react to mouse button changes
    mousedrag_observerfunc = on(events(scene).mousebutton, priority=priority) do event
        
        t = time()
        data = prev_data[]
        px = prev_px[]

        # TODO: this could probably be simplified by just using event.button
        # though that would probably change the way this handles a bit
        pressed_buttons = events(scene).mousebuttonstate[]
        
        # mouse went down, this can either happen inside or outside the objects of interest
        # we also only react if one button is pressed, because otherwise things go crazy (pressed left button plus clicks from other buttons in between are not allowed, e.g.)
        if event.action == Mouse.press
            if length(pressed_buttons) == 1
                button = only(pressed_buttons)
                mouse_downed_button[] = button

                if mouse_was_inside[]
                    event = @match mouse_downed_button[] begin
                        Mouse.left => MouseEventTypes.leftdown
                        Mouse.right => MouseEventTypes.rightdown
                        Mouse.middle => MouseEventTypes.middledown
                        x => error("No recognized mouse button $x")
                    end
                    mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])
                    mouse_downed_inside[] = true
                else
                    mouse_downed_inside[] = false
                    mouseevent[] = MouseEvent(MouseEventTypes.downoutside, t, data, px, prev_t[], prev_data[], prev_px[])
                end
            end
            last_mouseevent[] = Mouse.down
        elseif event.action == Mouse.release
            # only register up events and clicks if the upped button matches
            # the recorded downed one
            # and it can't be nothing (if the first up event comes from outside)

            downed_button_missing_from_pressed = !(mouse_downed_button[] in pressed_buttons)
            some_mouse_button_had_been_downed = !isnothing(mouse_downed_button[])

            if downed_button_missing_from_pressed && some_mouse_button_had_been_downed

                if drag_ongoing[]
                    event = @match mouse_downed_button[] begin
                        Mouse.left => MouseEventTypes.leftdragstop
                        Mouse.right => MouseEventTypes.rightdragstop
                        Mouse.middle => MouseEventTypes.middledragstop
                        x => error("No recognized mouse button $x")
                    end
                    mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])
                    drag_ongoing[] = false

                    if mouse_was_inside[]
                        # up after drag done over element
                        event = @match mouse_downed_button[] begin
                            Mouse.left => MouseEventTypes.leftup
                            Mouse.right => MouseEventTypes.rightup
                            Mouse.middle => MouseEventTypes.middleup
                            x => error("No recognized mouse button $x")
                        end

                        mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])
                    else
                        # mouse could be not over elements after drag is over
                        mouseevent[] = MouseEvent(MouseEventTypes.out, t, data, px, prev_t[], prev_data[], prev_px[])
                    end
                else
                    if mouse_was_inside[]
                        dt_last_click = t - t_last_click[]
                        t_last_click[] = t

                        # guard against mouse coming in from outside, then mouse upping
                        if mouse_downed_inside[]
                            if dt_last_click < dblclick_max_interval && !last_click_was_double[] &&
                                    mouse_downed_button[] == b_last_click[]

                                event = @match mouse_downed_button[] begin
                                    Mouse.left => MouseEventTypes.leftdoubleclick
                                    Mouse.right => MouseEventTypes.rightdoubleclick
                                    Mouse.middle => MouseEventTypes.middledoubleclick
                                    x => error("No recognized mouse button $x")
                                end
                                mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])
                                last_click_was_double[] = true
                            else
                                event = @match mouse_downed_button[] begin
                                    Mouse.left => MouseEventTypes.leftclick
                                    Mouse.right => MouseEventTypes.rightclick
                                    Mouse.middle => MouseEventTypes.middleclick
                                    x => error("No recognized mouse button $x")
                                end
                                mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])
                                last_click_was_double[] = false
                            end
                            # save what type the last downed button was
                            b_last_click[] = mouse_downed_button[]
                        end
                        mouse_downed_inside[] = false

                        # up after click
                        event = @match mouse_downed_button[] begin
                            Mouse.left => MouseEventTypes.leftup
                            Mouse.right => MouseEventTypes.rightup
                            Mouse.middle => MouseEventTypes.middleup
                            x => error("No recognized mouse button $x")
                        end

                        mouseevent[] = MouseEvent(event, t, data, px, prev_t[], prev_data[], prev_px[])
                    end
                end                
            end

            last_mouseevent[] = Mouse.up
        end
            

        prev_t[] = t
        return false
    end

    MouseEventHandle(mouseevent, [mousepos_observerfunc, mousedrag_observerfunc])
end
