// 运行在 WKContentWorld.defaultClient 隔离世界里，与页面本身的 JS 全局隔离。
// 由 MarkdownPreviewController 通过 callAsyncJavaScript 调用 window.MdViewer.*。
(function () {
  "use strict";

  var state = {
    markdown: "",
    mode: "rendered",       // "rendered" | "raw"
    remoteImagesEnabled: false
  };

  if (typeof marked !== "undefined" && marked.setOptions) {
    marked.setOptions({ gfm: true, breaks: false });
  }

  function contentElement() {
    return document.getElementById("content");
  }

  function highlight(root) {
    if (typeof hljs === "undefined") { return; }
    var blocks = root.querySelectorAll("pre code");
    for (var i = 0; i < blocks.length; i++) {
      try {
        hljs.highlightElement(blocks[i]);
      } catch (error) {
        // 单个代码块高亮失败不应影响整篇渲染，降级为纯代码块。
      }
    }
  }

  function brokenImagePlaceholder(img) {
    var src = img.getAttribute("src") || "";
    var alt = img.getAttribute("alt") || "";
    var span = document.createElement("span");
    span.className = "mdviewer-broken-image";

    var altLine = document.createElement("span");
    altLine.className = "mdviewer-broken-image-alt";
    altLine.textContent = alt.length > 0 ? alt : "图片不可用";
    span.appendChild(altLine);

    if (src.length > 0) {
      var srcLine = document.createElement("span");
      srcLine.className = "mdviewer-broken-image-src";
      srcLine.textContent = src;
      span.appendChild(srcLine);
    }
    return span;
  }

  function replaceWithPlaceholder(img) {
    if (!img.parentNode) { return; }
    img.parentNode.replaceChild(brokenImagePlaceholder(img), img);
  }

  // 页面以 baseURL=nil 加载，相对路径永远无法解析；远程图默认被 CSP 拦截。
  // 这两类在插入后立刻确定性替换，不依赖 error 事件（会有竞态）。
  function decorateImages(root) {
    var images = root.querySelectorAll("img");
    for (var i = images.length - 1; i >= 0; i--) {
      var img = images[i];
      var src = (img.getAttribute("src") || "").trim();
      var isData = /^data:/i.test(src);
      var isRemote = /^https:/i.test(src);

      if (src.length === 0 || (!isData && !isRemote)) {
        replaceWithPlaceholder(img);
        continue;
      }
      if (isRemote && !state.remoteImagesEnabled) {
        replaceWithPlaceholder(img);
        continue;
      }
      // 允许加载的图仍可能 404 / 超时，用 error 事件兜底。
      img.addEventListener("error", function (event) {
        replaceWithPlaceholder(event.target);
      });
    }
  }

  // DOMPurify 的 FORBID_TAGS 是「拆掉标签、保留子节点」，禁掉 form 之后里面的
  // input/button 会留在原地，渲染出一个点不动的假控件。只读预览里除了 GFM 任务列表的
  // 复选框，其余交互控件一律去掉。
  function stripInteractiveControls(root) {
    var controls = root.querySelectorAll("input, button, select, textarea");
    for (var i = controls.length - 1; i >= 0; i--) {
      var control = controls[i];
      var isTaskCheckbox = control.tagName === "INPUT" &&
        (control.getAttribute("type") || "").toLowerCase() === "checkbox";
      if (isTaskCheckbox) {
        control.disabled = true;
      } else if (control.parentNode) {
        control.parentNode.removeChild(control);
      }
    }
  }

  function renderRendered() {
    var content = contentElement();
    var html = marked.parse(state.markdown);
    // md 来自其他用户上传，可能含 <script> / onerror / <iframe>。
    // CSP 与 DOMPurify 双保险，两层任一失效都不至于被打穿。
    content.className = "markdown-body";
    // FORBID_TAGS: form —— 表单在只读预览里没有意义，留着会渲染出一个假的可交互控件
    // （提交虽被 CSP form-action 'none' 拦住，但会误导用户）。
    // input 必须保留，GFM 任务列表就是 <input type="checkbox">。
    content.innerHTML = DOMPurify.sanitize(html, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ["form"]
    });
    stripInteractiveControls(content);
    highlight(content);
    decorateImages(content);
  }

  function renderRaw() {
    var content = contentElement();
    content.className = "markdown-body mdviewer-raw";
    content.innerHTML = "";
    var pre = document.createElement("pre");
    var code = document.createElement("code");
    code.textContent = state.markdown;   // textContent，不走 HTML 解析
    pre.appendChild(code);
    content.appendChild(pre);
  }

  function apply() {
    if (state.mode === "raw") { renderRaw(); } else { renderRendered(); }
  }

  window.MdViewer = {
    render: function (markdown, remoteImagesEnabled) {
      state.markdown = typeof markdown === "string" ? markdown : "";
      state.remoteImagesEnabled = remoteImagesEnabled === true;
      apply();
      return true;
    },
    // 注意：切换远程图片开关必须由 Swift 侧整页重载完成——img-src 写死在 CSP meta 里，
    // 光改 JS 标志位不会让被拦截的图重新可加载。
    setMode: function (mode) {
      state.mode = mode === "raw" ? "raw" : "rendered";
      apply();
      return state.mode;
    }
  };
})();
