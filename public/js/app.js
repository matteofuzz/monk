// Loaded as <script type="module">, resolving "clock" through the import
// map in the layout. No bundler involved -- these are the bytes the
// browser gets.
import { start } from "clock";

const element = document.querySelector("#clock");
if (element) start(element);
