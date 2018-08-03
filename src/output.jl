using WebIO, JSExpr

const katex_min_js = joinpath(@__DIR__, "..", "assets",
                             "npm", "node_modules", "katex",
                             "dist", "katex.min.js")

const katex_min_css = joinpath(@__DIR__, "..", "assets",
                             "npm", "node_modules", "katex",
                             "dist", "katex.min.css")

"""
`latex(txt)`

Render `txt` in LaTeX using KaTeX. Backslashes need to be escaped:
`latex("\\\\sum_{i=1}^{\\\\infty} e^i")`
"""
function latex(txt)
   (txt isa Observable) || (txt = Observable(txt))
   w = Scope(imports=[
                      katex_min_js,
                      katex_min_css
                     ])

   w["value"] = txt

   onimport(w, @js function (k)
       this.k = k
       this.container = this.dom.querySelector("#container")
       k.render($(txt[]), this.container)
   end)

   onjs(w["value"], @js (txt) -> this.k.render(txt, this.container))

   w.dom = dom"div#container"()

   Widget{:latex}(scope = w, output = w["value"], layout = dom"div.field"∘Widgets.scope)
end

"""
`alert(text="")`

Creates a `Widget{:alert}`. To cause it to trigger an alert, do:

```julia
wdg = alert("Error!")
wdg()
```

Calling `wdg` with a string will set the alert message to that string before triggering the alert:

```julia
wdg = alert("Error!")
wdg("New error message!")
```

For the javascript to work, the widget needs to be part of the UI, even though it is not visible.
"""
function alert(text = ""; value = text)
   value isa Observable || (value = Observable(value))

   scp = WebIO.Scope()
   setobservable!(scp, "text", value)
   onjs(scp["text"], js"""function (value) {
      alert(value);
      }"""
   )
   Widget{:alert}(["text" => value]; scope = scp,
      layout = t -> Node(:div, Widgets.scope(t), style = Dict("visible" => false)))
end

widget(::Val{:alert}, args...; kwargs...) = alert(args...; kwargs...)

(wdg::Widget{:alert})(text = wdg["text"][]) = (wdg["text"][] = text; return)

"""
`confirm([f,] text="")`

Creates a `Widget{:confirm}`. To cause it to trigger a confirmation dialogue, do:

```julia
wdg = confirm([f,] "Are you sure you want to unsubscribe?")
wdg()
```

`observe(wdg)` is a `Observable{Bool}` and is set to `true` if the user clicks on "OK" in the dialogue,
or to false if the user closes the dialogue or clicks on "Cancel". When `observe(wdg)` is set, the function `f`
will be called with that value.

Calling `wdg` with a string and/or a function will set the confirmation message and/or the callback function:

```julia
wdg = confirm("Are you sure you want to unsubscribe?")
wdg("File exists, overwrite?") do x
   x ? print("Overwriting") : print("Aborting")
end
```

For the javascript to work, the widget needs to be part of the UI, even though it is not visible.
"""
function confirm(fct::Function = x -> nothing, text::AbstractString = "")
   text isa Observable || (text = Observable(text))

   scp = WebIO.Scope()
   setobservable!(scp, "text", text)
   value = Observable(scp, "value", false)
   onjs(scp["text"],
      @js function (txt)
         $value[] = confirm(txt)
      end)
   wdg = Widget{:confirm}(["text" => text, "function" => fct]; scope = scp, output = value,
      layout = t -> Node(:div, Widgets.scope(t), style = Dict("visible" => false)))
   on(x -> wdg["function"](x), value)
   wdg
end

confirm(text::AbstractString, fct::Function = x -> nothing) = confirm(fct, text)

widget(::Val{:confirm}, args...; kwargs...) = confirm(args...; kwargs...)

function (wdg::Widget{:confirm})(fct::Function = wdg["function"], text::AbstractString = wdg["text"][])
   wdg["function"] = fct
   wdg["text"][] = text
   return
end

(wdg::Widget{:confirm})(text::AbstractString, fct::Function = wdg["function"]) = wdg(fct, text)

"""
`highlight(txt; language = "julia")`

`language` syntax highlighting for `txt`.
"""
function highlight(txt; language = "julia")
    (txt isa Observable) || (txt = Observable(txt))

    s = "code"*randstring(16)

    w = Scope(imports = [
       style_css,
       prism_js,
       prism_css,
    ])

    w["value"] = txt

    w.dom = Node(
        :div,
        Node(
            :pre,
            Node(:code, className = "language-$language", attributes = Dict("id"=>s))
        ),
        className = "content"
    )

    onimport(w, js"""
        function (p) {
            var code = document.getElementById($s);
            code.innerHTML = $(txt[]);
            Prism.highlightElement(code);
        }
    """
    )

    onjs(w["value"], js"""
      function (val){
          var code = document.getElementById($s);
          code.innerHTML = val
          Prism.highlightElement(code)
      }
   """)

    Widget{:highlight}(scope = w, output = w["value"], layout = Widgets.scope)
end

widget(::Val{:highlight}, args...; kwargs...) = highlight(args...; kwargs...)

@widget wdg function notifications(::WidgetTheme, v=[]; layout = div, className = "")
    className = mergeclasses(className, "notification")
    @output! wdg Observable{Any}(v)
    :list = begin
        list = $(_.output)
        function create_item(ind, el)
            btn = button(className = "delete")
            on(observe(btn)) do x
                deleteat!(list, ind)
                _.output[] = _.output[]
            end
            div(btn, className = className, el)
        end
        [create_item(ind, el) for (ind, el) in enumerate(list)]
    end
    scope!(wdg, slap_design!(Scope()))
    Widgets.scope(wdg).dom = map(layout, wdg[:list])
    @layout! wdg Widgets.scope(_)
end

"""
`notifications(v=[]; layout = Node(:div))`

Display elements of `v` inside notification boxes that can be closed with a close button.
The elements are laid out according to `layout`.
`observe` on this widget returns the observable of the list of elements that have not bein deleted.
"""
notifications(args...; kwargs...) = notifications(gettheme(), args...; kwargs...)

"""
`accordion(options; multiple = true)`

Display `options` in an `accordion` menu. `options` is an `Associative` whose
keys represent the labels and whose values represent what is shown in each entry.

`options` can be an `Observable`, in which case the `accordion` updates as soon as
`options` changes.
"""
function accordion(::WidgetTheme, options::Observable;
    multiple = true, value = multiple ? Int[] : 1,
    index = value)

    (index isa Observable) || (index = Observable{Any}(index))

    option_array = map(x -> [OrderedDict("label" => key, "i" => i, "content" => stringmime(MIME"text/html"(), WebIO.render(val))) for (i, (key, val)) in enumerate(x)], options)

    onClick = multiple ? js"function (i) {this.index.indexOf(i) > -1 ? this.index.remove(i) : this.index.push(i)}" :
        js"function (i) {this.index(i)}"

    isactive = multiple ? "\$root.index.indexOf(i) > -1" : "\$root.index() == i"
    template = dom"section.accordions"(attributes = Dict("data-bind" => "foreach: options_js"),
        Node(:article, className="accordion", attributes = Dict("data-bind" => "css: {'is-active' : $isactive}", ))(
            dom"div.accordion-header.toggle"(dom"p"(attributes = Dict("data-bind" => "html: label")), attributes = Dict("data-bind" => "click: function () {\$root.onClick(i)}")),
            dom"div.accordion-body"(dom"div.accordion-content"(attributes = Dict("data-bind" => "html: content")))
        )
    )
    scp = knockout(template, ["index" => index, "options_js" => option_array], methods = Dict("onClick" => onClick))
    slap_design!(scp)
    Widget{:accordion}(["index" => index, "options" => options]; scope = scp, output = index, layout = Widgets.scope)
end

accordion(T::WidgetTheme, options; kwargs...) = accordion(T, Observable{Any}(options); kwargs...)

"""
`togglecontent(content, value::Union{Bool, Observable}=false; label)`

A toggle switch that, when activated, displays `content`
e.g. `togglecontent(checkbox("Yes, I am sure"), false, label="Are you sure?")`
"""
function togglecontent(::WidgetTheme, content, args...; vskip = 0em, kwargs...)
    btn = toggle(gettheme(), args...; kwargs...)
    Widgets.scope(btn).dom =  vbox(
        Widgets.scope(btn).dom,
        Node(:div,
            content,
            attributes = Dict("data-bind" => "visible: value")
        )
    )
    Widget{:togglecontent}(btn)
end
