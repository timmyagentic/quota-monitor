# Website interface

Run `npm ci && npm run build` to regenerate the deployable HTML, JavaScript, CSS and third-party notices. The project owns its JSX in `Page.jsx`, its page composition in `template.html`, and its typography and layout in `style.css`. The checked-in assets work with the existing static deployment.

HeroUI supplies the accessible controls. The browser hydrates the same React components used to render the initial HTML. All runtime assets are served by this site.
